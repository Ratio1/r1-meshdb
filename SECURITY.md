# Security Policy

## Supported Releases

Ratio1 supports only the newest published R1 Distributed SQL patch release.
The underlying CockroachDB v23.1 line is no longer supported upstream, so
Ratio1 independently assesses and backports applicable fixes. Support for this
engine line is transitional and does not promise indefinite maintenance or
store-format compatibility with a future engine replacement.

Every release and a scheduled weekly workflow scan source, dependencies, and
the OCI image. Critical or high findings are triaged before promotion; an
accepted residual finding must be documented by component, exploitability,
mitigation, owner, and review date.

## Reporting A Vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub's private
security-advisory reporting for this repository. If that channel is
unavailable, contact the Ratio1 security team through the security contact
published by the Ratio1 organization.

Include the affected image digest or source revision, reproduction steps,
impact, and any known mitigation. Do not include production credentials,
private keys, tunnel tokens, or customer data.

Ratio1 will acknowledge a valid report, assess severity and affected releases,
prepare a patch and coordinated disclosure where appropriate, and publish a
new immutable digest. Existing tags are not silently repointed as a substitute
for a security release.

## Operator Guidance

- Deploy only an immutable digest whose signature, issuer, workflow identity,
  provenance, and SBOM attestation have been verified.
- Keep cluster and client TLS enabled and protect Deeploy-generated private
  keys and tunnel tokens.
- Back up and test recovery before upgrades or rollbacks.
- Never start a store containing `.deeploy-recovery-v1` metadata with a Ratio1
  image that predates the supervised recovery implementation.

## Published Test Material

The source tree includes upstream public TLS fixtures required by the OSS CLI
dependency graph. They are explicitly nonproduction keys, are documented in
`THIRD_PARTY_NOTICES.md`, and are locked by
`source/public-test-fixtures.sha256`. The release workflow fails if any fixture
changes or any unapproved private key or token pattern is introduced. The
fixture files are not copied as standalone files into the runtime image.

## Vulnerability Assessments

Release scans consume `security/openvex.json`. Each exception must name one
exact package version, include a machine-verifiable justification, and remain
covered by `scripts/verify-security-vex.py`.

`CVE-2026-42154` affects Prometheus's unauthenticated `/api/v1/read` remote-read
handler in `github.com/prometheus/prometheus/storage/remote`. The OSS database
binary uses selected Prometheus labels, parser, storage-interface, and TSDB
utility packages, but the checked-in and verified runtime closure excludes the
`storage/remote` package and contains no Prometheus remote-read HTTP endpoint.
The exact Prometheus module is therefore present in Go build metadata while the
vulnerable code is not in the executable path.

`CVE-2026-32286` / `GO-2026-4518` affects negative field lengths decoded by
`github.com/jackc/pgproto3/v2` clients. The distributed v2.3.3 source contains
the maintained bounds-check fix and regressions for `-2`, minimum `int32`, a
valid `-1` null, and a complete malicious frontend frame. The scanner still
identifies the upstream module version, so the exact VEX decision is `fixed`;
the patch and test hashes are enforced by
`source/ratio1-engine-overrides.json`.

The final image is assembled from a tracked minimal root filesystem rather
than a complete Debian userspace. This removes Perl, gzip, zlib, block-device
parsers, mount tools, package managers, login tools, and ncurses commands while
retaining Debian package metadata and copyright files for every copied OS
component.

- `CVE-2026-53615` is in util-linux's DOS/EBR parser. Only `setsid` is retained;
  `libblkid`, `blkid`, `findmnt`, and mount utilities are absent, and the
  entrypoint reads `/proc/self/mountinfo` directly.
- `CVE-2025-69720` is in the `infocmp` command's `analyze_string` function.
  `infocmp`, ncurses commands, and `libncurses` are absent; only `libtinfo` is
  retained for Bash and the database binary.
- `CVE-2026-54369` affects pathname-based libacl operations. The final image
  contains neither `libacl` nor `mv`; recovery markers use a static Ratio1
  helper that accepts only same-directory regular-file replacements.

The release gate runs Trivy without `ignore-unfixed`. These exact source and
runtime decisions are the complete allowlist; any new high or critical finding
fails the release.
