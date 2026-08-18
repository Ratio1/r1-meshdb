# Licensing Overview

R1 Distributed SQL is a mixed-license distribution. The root [LICENSE](LICENSE)
is the Apache License 2.0 text that applies to Ratio1-authored files and to
upstream engine files whose Business Source License change license has taken
effect. It does not replace the licenses of included third-party source or
binaries.

Third-party components retain their original licenses. Their component-level
license conclusions, full notice locations, and source provenance are recorded
in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md),
[`source/license-inventory.json`](source/license-inventory.json), the release
SPDX and CycloneDX SBOMs, and the license files shipped in the source and image.

The OCI expression
`Apache-2.0 AND LicenseRef-R1-Distributed-SQL-Third-Party` identifies this
combined distribution contract. The custom reference is defined in each
generated SPDX SBOM and does not alter, replace, or sublicense any underlying
third-party license. CycloneDX consumers can resolve the same reference through
the companion SPDX SBOM distributed with each release.
