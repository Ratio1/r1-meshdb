#!/usr/bin/env python3
# Copyright 2026 Ratio1
# Licensed under the Apache License, Version 2.0. See LICENSE.

import io
import json
from pathlib import Path
import stat
import tempfile
import unittest
from urllib import error
from urllib.parse import parse_qs, urlparse

from scripts.cloudflare_ephemeral_tunnels import (
  CloudflareClient,
  CloudflareError,
  allocate,
  cleanup_allocations,
  cleanup_run_prefix,
  cleanup_state_allocations,
  load_state,
)


class Response(io.BytesIO):
  def __enter__(self):
    return self

  def __exit__(self, *_args):
    self.close()


class FakeCloudflare:
  def __init__(
    self,
    fail_dns_at: int | None = None,
    fail_tunnel_delete: bool = False,
    lose_tunnel_response_at: int | None = None,
    lose_dns_response_at: int | None = None,
  ):
    self.calls = []
    self.created = 0
    self.fail_dns_at = fail_dns_at
    self.fail_tunnel_delete = fail_tunnel_delete
    self.lose_tunnel_response_at = lose_tunnel_response_at
    self.lose_dns_response_at = lose_dns_response_at
    self.tunnels = {}
    self.dns_records = {}

  def __call__(self, req, timeout):
    body = json.loads(req.data) if req.data else None
    self.calls.append((req.method, req.full_url, body, timeout))
    parsed = urlparse(req.full_url)
    query = parse_qs(parsed.query)
    if req.method == "POST" and parsed.path.endswith("/cfd_tunnel"):
      self.created += 1
      result = {
        "id": f"tunnel-{self.created}",
        "name": body["name"],
        "token": f"secret-token-{self.created}",
      }
      self.tunnels[result["id"]] = result
      if self.lose_tunnel_response_at == self.created:
        raise error.URLError("response lost after tunnel creation")
    elif req.method == "GET" and parsed.path.endswith("/cfd_tunnel"):
      if "include_prefix" in query:
        prefix = query["include_prefix"][0]
        result = [
          tunnel for tunnel in self.tunnels.values()
          if tunnel["name"].startswith(prefix)
        ]
      else:
        result = [
          tunnel for tunnel in self.tunnels.values()
          if tunnel["name"] == query.get("name", [None])[0]
        ]
    elif req.method == "POST" and parsed.path.endswith("/dns_records"):
      if self.fail_dns_at == self.created:
        raise error.HTTPError(req.full_url, 400, "bad request", {}, None)
      result = {"id": f"dns-{self.created}", "name": body["name"], "content": body["content"]}
      self.dns_records[result["id"]] = result
      if self.lose_dns_response_at == self.created:
        raise error.URLError("response lost after DNS creation")
    elif req.method == "GET" and parsed.path.endswith("/dns_records"):
      if "name.startswith" in query:
        prefix = query["name.startswith"][0]
        result = [
          record for record in self.dns_records.values()
          if record["name"].startswith(prefix)
        ]
      else:
        result = [
          record for record in self.dns_records.values()
          if record["name"] == query.get("name", [None])[0]
          and record["content"] == query.get("content", [None])[0]
        ]
    elif req.method == "DELETE" and "/cfd_tunnel/" in req.full_url:
      if self.fail_tunnel_delete:
        raise error.HTTPError(req.full_url, 409, "connector active", {}, None)
      self.tunnels.pop(parsed.path.rsplit("/", 1)[-1], None)
      result = {"id": "deleted"}
    elif req.method == "DELETE" and "/dns_records/" in req.full_url:
      self.dns_records.pop(parsed.path.rsplit("/", 1)[-1], None)
      result = {"id": "deleted"}
    else:
      result = {"id": "deleted"}
    return Response(json.dumps({"success": True, "result": result}).encode())


def client(fake: FakeCloudflare) -> CloudflareClient:
  return CloudflareClient(
    "account", "zone", "api-secret", "ci.example.com", opener=fake, api_root="https://mock.invalid"
  )


class EphemeralTunnelTests(unittest.TestCase):
  def test_allocate_persists_tokens_only_in_owner_readable_files(self):
    fake = FakeCloudflare()
    suffixes = iter(("aaaa", "bbbb", "cccc"))
    with tempfile.TemporaryDirectory() as tmp:
      output = Path(tmp) / "allocation"
      state = allocate(client(fake), output, 3, "r1-meshdb-ci", lambda: next(suffixes))
      self.assertEqual(len(state["tunnels"]), 3)
      persisted = load_state(output / "state.json")
      self.assertNotIn("secret-token", json.dumps(persisted))
      for index in range(1, 4):
        token = output / f"node-{index}.token"
        self.assertEqual(token.read_text(), f"secret-token-{index}")
        self.assertEqual(stat.S_IMODE(token.stat().st_mode), 0o600)
      self.assertEqual(stat.S_IMODE((output / "state.json").stat().st_mode), 0o600)
      authorization = fake.calls[0][1]
      self.assertNotIn("api-secret", authorization)

  def test_partial_failure_deletes_created_dns_then_tunnels(self):
    fake = FakeCloudflare(fail_dns_at=2)
    with tempfile.TemporaryDirectory() as tmp:
      with self.assertRaises(CloudflareError):
        allocate(client(fake), Path(tmp) / "allocation", 3, "r1-meshdb-ci", lambda: "fixed")
    deletes = [(method, url) for method, url, _body, _timeout in fake.calls if method == "DELETE"]
    self.assertEqual(
      deletes,
      [
        ("DELETE", "https://mock.invalid/zones/zone/dns_records/dns-1"),
        ("DELETE", "https://mock.invalid/accounts/account/cfd_tunnel/tunnel-2"),
        ("DELETE", "https://mock.invalid/accounts/account/cfd_tunnel/tunnel-1"),
      ],
    )

  def test_cleanup_uses_reverse_dns_then_reverse_tunnel_order(self):
    fake = FakeCloudflare()
    allocations = [
      {"id": "tunnel-1", "dnsRecordId": "dns-1"},
      {"id": "tunnel-2", "dnsRecordId": "dns-2"},
    ]
    self.assertEqual(cleanup_allocations(client(fake), allocations), [])
    paths = [url.removeprefix("https://mock.invalid") for method, url, _body, _timeout in fake.calls if method == "DELETE"]
    self.assertEqual(
      paths,
      [
        "/zones/zone/dns_records/dns-2",
        "/zones/zone/dns_records/dns-1",
        "/accounts/account/cfd_tunnel/tunnel-2",
        "/accounts/account/cfd_tunnel/tunnel-1",
      ],
    )

  def test_lost_tunnel_create_response_is_discovered_and_cleaned_by_name(self):
    fake = FakeCloudflare(lose_tunnel_response_at=1)
    with tempfile.TemporaryDirectory() as tmp:
      output = Path(tmp) / "allocation"
      with self.assertRaises(CloudflareError):
        allocate(client(fake), output, 1, "r1-meshdb-ci", lambda: "lost")
      self.assertFalse((output / "state.json").exists())
    delete_urls = [url for method, url, _body, _timeout in fake.calls if method == "DELETE"]
    self.assertEqual(
      delete_urls,
      ["https://mock.invalid/accounts/account/cfd_tunnel/tunnel-1"],
    )

  def test_lost_dns_create_response_is_discovered_and_cleaned_by_content(self):
    fake = FakeCloudflare(lose_dns_response_at=1)
    with tempfile.TemporaryDirectory() as tmp:
      output = Path(tmp) / "allocation"
      with self.assertRaises(CloudflareError):
        allocate(client(fake), output, 1, "r1-meshdb-ci", lambda: "lost")
      self.assertFalse((output / "state.json").exists())
    delete_urls = [url for method, url, _body, _timeout in fake.calls if method == "DELETE"]
    self.assertEqual(
      delete_urls,
      [
        "https://mock.invalid/zones/zone/dns_records/dns-1",
        "https://mock.invalid/accounts/account/cfd_tunnel/tunnel-1",
      ],
    )

  def test_partial_failure_keeps_recoverable_state_when_cleanup_fails(self):
    fake = FakeCloudflare(fail_dns_at=2, fail_tunnel_delete=True)
    with tempfile.TemporaryDirectory() as tmp:
      output = Path(tmp) / "allocation"
      with self.assertRaisesRegex(CloudflareError, "cleanup left 2"):
        allocate(client(fake), output, 3, "r1-meshdb-ci", lambda: "fixed")
      state = load_state(output / "state.json")
      self.assertEqual([item["id"] for item in state["tunnels"]], ["tunnel-1", "tunnel-2"])
      self.assertFalse(list(output.glob("*.token")))
      self.assertNotIn("secret-token", (output / "state.json").read_text())

  def test_load_state_rejects_resource_id_path_injection(self):
    with tempfile.TemporaryDirectory() as tmp:
      state_path = Path(tmp) / "state.json"
      state_path.write_text(json.dumps({
        "schemaVersion": 1,
        "accountId": "account",
        "zoneId": "zone",
        "baseDomain": "ci.example.com",
        "tunnels": [{
          "id": "../../other-tunnel",
          "hostname": "node.ci.example.com",
          "nodeIndex": 1,
        }],
      }))
      state_path.chmod(0o600)
      with self.assertRaisesRegex(CloudflareError, "invalid tunnel id"):
        load_state(state_path)

  def test_load_state_binds_recovery_to_the_expected_run_prefix(self):
    with tempfile.TemporaryDirectory() as tmp:
      state_path = Path(tmp) / "state.json"
      name = "r1-meshdb-ci-12345-2-1-deadbeef"
      state_path.write_text(json.dumps({
        "schemaVersion": 1,
        "accountId": "account",
        "zoneId": "zone",
        "baseDomain": "ci.example.com",
        "tunnels": [{
          "id": "tunnel-1",
          "name": name,
          "hostname": f"{name}.ci.example.com",
          "nodeIndex": 1,
        }],
      }))
      state_path.chmod(0o600)
      self.assertEqual(
        load_state(state_path, expected_run_prefix="r1-meshdb-ci-12345-2")["tunnels"][0]["id"],
        "tunnel-1",
      )
      with self.assertRaisesRegex(CloudflareError, "requested run prefix"):
        load_state(state_path, expected_run_prefix="r1-meshdb-ci-12345-3")

  def test_cleanup_run_prefix_deletes_only_the_exact_attempt_namespace(self):
    fake = FakeCloudflare()
    exact_name = "r1-meshdb-ci-12345-2-1-deadbeef"
    exact_id = "tunnel-exact"
    fake.tunnels = {
      exact_id: {"id": exact_id, "name": exact_name, "config_src": "local"},
      "tunnel-next-attempt": {
        "id": "tunnel-next-attempt",
        "name": "r1-meshdb-ci-12345-20-1-feedface",
        "config_src": "local",
      },
      "tunnel-other-run": {
        "id": "tunnel-other-run",
        "name": "r1-meshdb-ci-123456-2-1-cafebabe",
        "config_src": "local",
      },
    }
    fake.dns_records = {
      "dns-exact": {
        "id": "dns-exact",
        "name": f"{exact_name}.ci.example.com",
        "content": f"{exact_id}.cfargotunnel.com",
      },
    }

    self.assertEqual(cleanup_run_prefix(client(fake), "r1-meshdb-ci-12345-2", retries=1), 1)
    deletes = [url for method, url, _body, _timeout in fake.calls if method == "DELETE"]
    self.assertEqual(
      deletes,
      [
        "https://mock.invalid/zones/zone/dns_records/dns-exact",
        "https://mock.invalid/accounts/account/cfd_tunnel/tunnel-exact",
      ],
    )
    self.assertIn("tunnel-next-attempt", fake.tunnels)
    self.assertIn("tunnel-other-run", fake.tunnels)

    self.assertEqual(cleanup_run_prefix(client(fake), "r1-meshdb-ci-12345-2", retries=1), 0)

  def test_cleanup_run_prefix_rejects_ambiguous_or_oversized_matches(self):
    fake = FakeCloudflare()
    with self.assertRaisesRegex(CloudflareError, "run prefix"):
      cleanup_run_prefix(client(fake), "r1-meshdb-ci-12345", retries=1)
    self.assertFalse(fake.calls)

    fake.tunnels = {
      f"tunnel-{index}": {
        "id": f"tunnel-{index}",
        "name": f"r1-meshdb-ci-12345-2-{index}-deadbeef",
        "config_src": "local",
      }
      for index in range(1, 5)
    }
    with self.assertRaisesRegex(CloudflareError, "more than three"):
      cleanup_run_prefix(client(fake), "r1-meshdb-ci-12345-2", retries=1)
    self.assertFalse([call for call in fake.calls if call[0] == "DELETE"])

  def test_cleanup_run_prefix_removes_dns_orphan_without_deleting_its_target(self):
    fake = FakeCloudflare()
    name = "r1-meshdb-ci-12345-2-1-deadbeef"
    fake.tunnels = {
      "unrelated-tunnel": {
        "id": "unrelated-tunnel",
        "name": "unrelated-production-tunnel",
        "config_src": "local",
      },
    }
    fake.dns_records = {
      "dns-orphan": {
        "id": "dns-orphan",
        "name": f"{name}.ci.example.com",
        "content": "unrelated-tunnel.cfargotunnel.com",
      },
    }
    self.assertEqual(cleanup_run_prefix(client(fake), "r1-meshdb-ci-12345-2", retries=1), 1)
    deletes = [url for method, url, _body, _timeout in fake.calls if method == "DELETE"]
    self.assertEqual(
      deletes,
      ["https://mock.invalid/zones/zone/dns_records/dns-orphan"],
    )
    self.assertIn("unrelated-tunnel", fake.tunnels)

  def test_recovery_state_ids_never_drive_deletion(self):
    fake = FakeCloudflare()
    name = "r1-meshdb-ci-12345-2-1-deadbeef"
    fake.tunnels = {
      "actual-tunnel": {
        "id": "actual-tunnel",
        "name": name,
        "config_src": "local",
      },
      "unrelated-tunnel": {
        "id": "unrelated-tunnel",
        "name": "unrelated-production-tunnel",
        "config_src": "local",
      },
    }
    state = {
      "tunnels": [{
        "id": "unrelated-tunnel",
        "name": name,
        "hostname": f"{name}.ci.example.com",
        "nodeIndex": 1,
      }],
    }
    self.assertEqual(
      cleanup_state_allocations(
        client(fake),
        state,
        expected_run_prefix="r1-meshdb-ci-12345-2",
        retries=1,
      ),
      1,
    )
    deleted_tunnels = [
      url.rsplit("/", 1)[-1]
      for method, url, _body, _timeout in fake.calls
      if method == "DELETE" and "/cfd_tunnel/" in url
    ]
    self.assertEqual(deleted_tunnels, ["actual-tunnel"])
    self.assertIn("unrelated-tunnel", fake.tunnels)


if __name__ == "__main__":
  unittest.main()
