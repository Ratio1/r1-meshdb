# R1DB v1.0.7

R1DB is an independently maintained Ratio1 distribution of a
source-derived OSS runtime closure from CockroachDB v23.1.28. It packages the
OSS database engine with the runtime entrypoint used by the Ratio1 Deeploy
service.

This project is not affiliated with or endorsed by Cockroach Labs. CockroachDB
is a trademark of Cockroach Labs, Inc. The original engine source and its
copyright notices are retained under `engine/`.

## Version

The current R1DB product version is `1.0.7`. [`VERSION`](VERSION) is the
single source of truth: the build validates it, installs it in the image at
`/usr/share/r1db/VERSION`, and records it in generated SPDX and CycloneDX
SBOM application metadata. A merged `VERSION` change automatically starts the
signed release workflow; the file must contain canonical `MAJOR.MINOR.PATCH`.

## Image

The release image is published as:

```text
ghcr.io/ratio1/r1db
```

Release workflows publish an immutable version tag and update `latest` only
after release publication. The separate protected promotion workflow moves
`stable` to an explicitly selected published version. Ratio1 Deeploy consumes
`stable` with an always-pull policy so a service restart can adopt the promoted
digest; consumers that require a fixed runtime must continue to use an
immutable digest.

The executable intentionally remains `/cockroach/cockroach` to preserve the
upstream wire protocol, on-disk format, diagnostic tooling, and existing
Deeploy runtime contract. A release binary must pass:

```bash
./cockroach version | grep -F 'Distribution:     OSS'
```

Deeploy sets `CRDB_NUM_REPLICAS` and `CRDB_NUM_VOTERS` to the selected node
count. The entrypoint applies both values to the default range configuration,
so application ranges place one voting replica on every selected node. Both
settings default to `3` when omitted for compatibility with existing jobs.

## Browser Console

The first-party console is served from the dashboard page and uses the same
origin through the Deeploy HTTP tunnel. After `POST /api/v2/login/`, the
browser sends the returned `X-Cockroach-API-Session` value on subsequent
requests. The SQL result view keeps the existing bounded response limit and
adds a scrollable table with client-side page sizes of 25, 50, or 100 rows.
Overview shows a short table inventory. Tables opens with the object list and
offers table creation on demand. Manage separates database, user, and access
tasks into tabs; database grants use explicit multi-selection controls.

The console uses these authenticated, same-origin endpoints. The management
endpoints cover operations that the generic SQL endpoint intentionally rejects:

- `GET /api/v2/r1db/version/` returns
  `{ "version": "1.0.7" }`, reading the installed R1DB image version
  from `/usr/share/r1db/VERSION`.
- `GET /api/v2/r1db/capabilities/` reports whether the session can view
  access administration or create databases.
- `GET /api/v2/r1db/databases/` lists databases where the session has
  `CONNECT`; `POST /api/v2/r1db/databases/` creates `{ "name": "appdb" }`
  with public database `CONNECT` and public-schema `CREATE` revoked atomically.
  The database creator retains schema `CREATE`.
- `GET /api/v2/r1db/database-tables/?database=appdb` lists tables using a
  query parameter so valid database names do not depend on URL path patterns.
- `POST /api/v2/r1db/tables/` with a database, schema, table name, and
  allowlisted column definitions. The endpoint enforces the caller's CREATE
  privilege on the selected database.
- `GET /api/v2/r1db/users/` lists users. `POST` creates a user with
  `{ "username": "app", "password": "..." }`. `DELETE` accepts
  `{ "username": "app" }` and returns `{ "username": "app" }` after dropping
  the user. The admin-only endpoint rejects the current or protected account;
  the database also rejects deletion while grants, ownership, or dependent jobs
  remain.
- `GET` or `POST /api/v2/r1db/access/` for a user, database, and optional
  table. POST requests may send a `databases` array to apply one database-scope
  grant or revoke to multiple databases in one operation. Access changes accept
  only `viewer` or `editor` presets and `grant` or `revoke` actions.
- `GET /api/v2/r1db/permissions/?username=app` returns paginated
  database, schema, and table grants and labels each source as direct, public,
  or a role. System-schema objects are excluded.

The Users & access view is restricted to authenticated admin users. It offers
typed-name confirmation before deleting an account. The API
enforces the same boundary, so hiding the navigation item is not the security
control. Ordinary SQL users can still use the console and receive normal SQL
privilege errors when they select or modify objects they cannot access.
The configured `CRDB_USER` is granted the cluster-wide `admin` role during
bootstrap, including when an existing cluster restarts on this image. Protect
and rotate `CRDB_PASSWORD` as an administrator credential; create separate
least-privilege users for applications.

Creating a user and applying its initial access are separate operations. If
the user is created but the access grant fails, the console reports that
partial result and the existing access editor can retry it. Table grants apply
only to the selected table; database `viewer` grants `CONNECT`, database
`editor` grants `CONNECT, CREATE` plus `CREATE` on the public schema, table
`viewer` grants `SELECT`, and table `editor` grants `SELECT, INSERT, UPDATE,
DELETE`. Table grants also grant database `CONNECT`. Revoking table access does
not revoke `CONNECT`, which may still support other grants.
Existing databases retain their current public grants; creating a database
through this console does not change privileges on older databases.

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
docker build -t r1db:local .
docker run --rm --entrypoint /cockroach/cockroach \
  r1db:local version
```

Run source and release-contract checks with:

```bash
python3 -m unittest tests.test_release_contract tests.test_sbom_contract
python3 scripts/verify-source-boundary.py --worktree-only
python3 scripts/generate-license-inventory.py --check
python3 scripts/verify-provenance.py
scripts/verify-upstream-provenance.sh  # authoritative; requires Docker and network access
python3 scripts/verify-public-test-fixtures.py
python3 scripts/verify-security-vex.py
python3 scripts/generate-source-manifest.py --check
```

The multi-node runtime suite is documented in [testbed/README.md](testbed/README.md).

## Supply Chain

Releases include SPDX JSON and CycloneDX JSON SBOMs, GitHub build provenance,
an OCI SBOM attestation, a keyless Cosign signature recorded in Rekor, exact
vendored dependency notices, and a checksum-backed Debian corresponding-source
bundle both inside the image and as a release asset.
Verification is bound to the Ratio1 repository workflow identity; executable
commands are in `scripts/verify-image.sh`.
Repository and package promotion controls are documented in
[RELEASE.md](RELEASE.md).

```bash
scripts/verify-image.sh \
  ghcr.io/ratio1/r1db@sha256:<digest> \
  v1.0.7
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
components retain their own licenses. See
[LICENSE-OVERVIEW.md](LICENSE-OVERVIEW.md), [LICENSE](LICENSE), [NOTICE](NOTICE),
and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Citation

The R1DB entry below cites this source snapshot. Its immutable `v1.0.7`
tag will make the citation reproducible once the release is published.

```bibtex
@software{cockroachdb_23_1_28,
  author  = {{Cockroach Labs, Inc.} and {The Cockroach Authors}},
  title   = {{CockroachDB}},
  version = {23.1.28},
  date    = {2024-10-10},
  url     = {https://www.cockroachlabs.com/docs/releases/v23.1#v23-1-28},
  note    = {Tag v23.1.28; commit 76e598c9b1c100fd9280b979140b5e377c330a20}
}

@software{ratio1_meshdb_1_0_6,
  author  = {{Ratio1}},
  title   = {{R1DB}},
  version = {1.0.7},
  url     = {https://github.com/Ratio1/r1db},
  note    = {Source-derived Ratio1 distribution based on CockroachDB v23.1.28}
}
```
