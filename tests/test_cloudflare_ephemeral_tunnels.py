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
      result = [
        record for record in self.dns_records.values()
        if record["name"] == query.get("name", [None])[0]
        and record["content"] == query.get("content", [None])[0]
      ]
    elif req.method == "DELETE" and "/cfd_tunnel/" in req.full_url and self.fail_tunnel_delete:
      raise error.HTTPError(req.full_url, 409, "connector active", {}, None)
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
      state = allocate(client(fake), output, 3, "r1-sql-ci", lambda: next(suffixes))
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
        allocate(client(fake), Path(tmp) / "allocation", 3, "r1-sql-ci", lambda: "fixed")
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
        allocate(client(fake), output, 1, "r1-sql-ci", lambda: "lost")
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
        allocate(client(fake), output, 1, "r1-sql-ci", lambda: "lost")
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
        allocate(client(fake), output, 3, "r1-sql-ci", lambda: "fixed")
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


if __name__ == "__main__":
  unittest.main()
