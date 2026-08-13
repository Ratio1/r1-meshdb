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
