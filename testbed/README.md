# Local Three-Node Testbed

Run the testbed only after the candidate image passes the source/release
contract checks. First it runs the unmodified candidate image as a three-node
secure engine cluster. It then derives a disposable local-only transport image
that adds a repository-built static TCP proxy and replaces only Cloudflared
with a deterministic test adapter; database binary and production entrypoint
hashes must remain equal to the candidate. That phase exercises the complete
Deeploy entrypoint contract. Both phases use the production 500 ms clock-offset
bound, write 10,000 rows, stop/rejoin a member, restart the fleet, validate
persistence, and assert cleanup. The co-located entrypoint phase uses fixed
128 MiB cache and SQL-memory budgets so each member does not independently
reserve a quarter of the entire Docker VM; the unmodified-image phase still
exercises the image defaults.

```bash
python3 -m unittest tests.test_release_contract
testbed/run-local-cluster.sh \
  ghcr.io/ratio1/r1-distributed-sql@sha256:<verified-digest>
```

For a pre-publication local image only, set `R1_SQL_REQUIRE_DIGEST=false`.
Such a run is build feedback and does not satisfy the signed-artifact gate.
The local transport overlay also does not prove Cloudflare behavior. The
unmodified signed digest with real tunnels is required in the hybrid testbed.
Database stores use disposable Docker-managed volumes. This avoids host
bind-mount `fsync` behavior becoming a false CockroachDB disk-stall failure and
more closely matches the dedicated Linux filesystems used by edge-node fixed
volumes; every harness asserts that its named volumes are deleted on exit.

`run-rolling-upgrade.sh` starts three members from the exact legacy service
digest with persistent stores, validates operator delegation and 10,000 rows,
replaces members one at a time with the candidate, then rolls them back one at
a time. It verifies SQL availability while each member is stopped, full
three-voter replication after each rejoin, unchanged database/entrypoint bytes
in the test transport overlays, and persistence of both operator and delegated
user data.

The signed-release workflow runs `run-real-cloudflare-cluster.sh` against the
unchanged immutable candidate before any human-facing image tag is created. It
creates three ephemeral tunnels under a disposable release subdomain, places
every node on a separate Docker bridge, validates replication and one-node
failover through the real tunnel path, checks process environments and logs for
secrets, and deletes all DNS and tunnel resources on exit.
If Cloudflare rejects cleanup after retries, token files are deleted and the
non-secret resource identifiers are retained as
`cloudflare-cleanup-state.json` in a seven-day, attempt-specific artifact. The
`Recover ephemeral Cloudflare resources` workflow runs automatically after an
unsuccessful release attempt. It validates the exact repository, workflow,
branch, run ID, and attempt before using that state, then verifies the
deterministic `r1-sql-ci-<run-id>-<attempt>` namespace through the Cloudflare
API. If the artifact is unavailable after runner loss, the same exact-prefix
lookup removes matching DNS records and tunnels without touching adjacent run
or attempt namespaces.

The recovery workflow can also be started manually from GitHub Actions with a
failed release run ID. Leaving the attempt empty selects the latest completed
attempt; specify an older failed attempt after a rerun. Successful, active,
foreign-repository, non-main, and non-release attempts are rejected. Cleanup is
idempotent, and downloaded artifact content is treated only as validated data.

CI and release also run `scripts/runtime-supervision-smoke.sh` against the
exact candidate. Its scratch-compatible multistage overlay preserves the
candidate database binary and production entrypoint byte-for-byte while adding
only static test transport and fault-injection wrappers. This validates process
supervision and corrupt-store recovery without installing tools into, or
rebuilding, the production image.

The protected `release` environment must provide scoped `CF_ACCOUNT_ID`,
`CF_ZONE_ID`, `CF_API_TOKEN`, and `CF_BASE_DOMAIN` secrets. The API token must
be dedicated to CI and limited to the selected account and disposable zone.
Restrict that environment to the `main` branch. If it requires reviewer
approval, automatic recovery waits for the same approval before using its
Cloudflare credentials.
