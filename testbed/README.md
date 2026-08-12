# Local Three-Node Testbed

Run the testbed only after the candidate image passes the source/release
contract checks. First it runs the unmodified candidate image as a three-node
secure engine cluster. It then derives a disposable local-only transport image
that adds `socat` and replaces only Cloudflared with a deterministic peer proxy;
binary and entrypoint hashes must remain equal to the candidate. That phase
exercises the complete Deeploy entrypoint contract. Both phases use the
production 500 ms clock-offset bound, write 10,000 rows, stop/rejoin a member,
restart the fleet, validate persistence, and assert cleanup.

```bash
python3 -m unittest tests.test_release_contract
testbed/run-local-cluster.sh \
  ghcr.io/ratio1/r1-distributed-sql@sha256:<verified-digest>
```

For a pre-publication local image only, set `R1_SQL_REQUIRE_DIGEST=false`.
Such a run is build feedback and does not satisfy the signed-artifact gate.
The local transport overlay also does not prove Cloudflare behavior. The
unmodified signed digest with real tunnels is required in the hybrid testbed.
