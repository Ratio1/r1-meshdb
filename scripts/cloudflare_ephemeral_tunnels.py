#!/usr/bin/env python3
"""Allocate and clean up short-lived Cloudflare tunnels for release validation."""

# Copyright 2026 Ratio1
# Licensed under the Apache License, Version 2.0. See LICENSE.

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import secrets
import stat
import sys
import time
from typing import Callable
from urllib import error, request
from urllib.parse import urlencode


API_ROOT = "https://api.cloudflare.com/client/v4"
STATE_FILE = "state.json"
RESOURCE_ID = re.compile(r"[A-Za-z0-9_-]{1,128}")
RUN_PREFIX = re.compile(r"r1-sql-ci-[1-9][0-9]*-[1-9][0-9]*")


class CloudflareError(RuntimeError):
  pass


class CloudflareClient:
  def __init__(
    self,
    account_id: str,
    zone_id: str,
    api_token: str,
    base_domain: str,
    opener: Callable = request.urlopen,
    api_root: str = API_ROOT,
  ) -> None:
    self.account_id = account_id
    self.zone_id = zone_id
    self.api_token = api_token
    self.base_domain = base_domain.strip(".").lower()
    self.opener = opener
    self.api_root = api_root.rstrip("/")
    for label, value in (
      ("account id", account_id),
      ("zone id", zone_id),
      ("API token", api_token),
      ("base domain", self.base_domain),
    ):
      if not value:
        raise CloudflareError(f"Cloudflare {label} is required")
    if not re.fullmatch(r"[a-z0-9.-]+", self.base_domain) or "." not in self.base_domain:
      raise CloudflareError("Cloudflare base domain is invalid")

  def call(self, method: str, path: str, payload: dict | None = None, allow_missing: bool = False):
    body = None if payload is None else json.dumps(payload, separators=(",", ":")).encode("utf-8")
    req = request.Request(
      f"{self.api_root}{path}",
      data=body,
      method=method,
      headers={
        "Authorization": f"Bearer {self.api_token}",
        "Accept": "application/json",
        "Content-Type": "application/json",
      },
    )
    try:
      with self.opener(req, timeout=30) as response:
        parsed = json.load(response)
    except error.HTTPError as exc:
      if allow_missing and exc.code == 404:
        return None
      raise CloudflareError(f"Cloudflare API {method} {path} returned HTTP {exc.code}") from exc
    except (error.URLError, TimeoutError, json.JSONDecodeError) as exc:
      raise CloudflareError(f"Cloudflare API {method} {path} failed") from exc
    if not isinstance(parsed, dict) or parsed.get("success") is not True:
      raise CloudflareError(f"Cloudflare API {method} {path} returned an unsuccessful response")
    return parsed.get("result")

  def create_tunnel(self, name: str) -> tuple[str, str]:
    result = self.call(
      "POST",
      f"/accounts/{self.account_id}/cfd_tunnel",
      {"name": name, "config_src": "local"},
    )
    tunnel_id = result.get("id") if isinstance(result, dict) else None
    token = result.get("token") if isinstance(result, dict) else None
    if not isinstance(tunnel_id, str) or not tunnel_id or not isinstance(token, str) or not token:
      raise CloudflareError("Cloudflare tunnel response omitted its id or token")
    return tunnel_id, token

  def create_dns(self, hostname: str, tunnel_id: str) -> str:
    result = self.call(
      "POST",
      f"/zones/{self.zone_id}/dns_records",
      {
        "type": "CNAME",
        "proxied": True,
        "name": hostname,
        "content": f"{tunnel_id}.cfargotunnel.com",
      },
    )
    record_id = result.get("id") if isinstance(result, dict) else None
    if not isinstance(record_id, str) or not record_id:
      raise CloudflareError("Cloudflare DNS response omitted its id")
    return record_id

  def find_tunnel_ids(self, name: str) -> list[str]:
    query = urlencode({"name": name, "is_deleted": "false"})
    result = self.call("GET", f"/accounts/{self.account_id}/cfd_tunnel?{query}")
    if not isinstance(result, list):
      raise CloudflareError("Cloudflare tunnel lookup returned an invalid result")
    return [
      item["id"]
      for item in result
      if isinstance(item, dict)
      and item.get("name") == name
      and isinstance(item.get("id"), str)
      and RESOURCE_ID.fullmatch(item["id"])
    ]

  def find_run_tunnels(self, prefix: str) -> list[dict]:
    query = urlencode({
      "include_prefix": f"{prefix}-",
      "is_deleted": "false",
      "per_page": "1000",
    })
    result = self.call("GET", f"/accounts/{self.account_id}/cfd_tunnel?{query}")
    if not isinstance(result, list):
      raise CloudflareError("Cloudflare run tunnel lookup returned an invalid result")
    if len(result) >= 1000:
      raise CloudflareError("Cloudflare run tunnel lookup is ambiguous")
    return result

  def find_run_dns_records(self, prefix: str) -> list[dict]:
    query = urlencode({
      "type": "CNAME",
      "name.startswith": f"{prefix}-",
      "per_page": "1000",
    })
    result = self.call("GET", f"/zones/{self.zone_id}/dns_records?{query}")
    if not isinstance(result, list):
      raise CloudflareError("Cloudflare run DNS lookup returned an invalid result")
    if len(result) >= 1000:
      raise CloudflareError("Cloudflare run DNS lookup is ambiguous")
    return result

  def find_dns_record_ids(self, hostname: str, tunnel_id: str) -> list[str]:
    content = f"{tunnel_id}.cfargotunnel.com"
    query = urlencode({"type": "CNAME", "name": hostname, "content": content})
    result = self.call("GET", f"/zones/{self.zone_id}/dns_records?{query}")
    if not isinstance(result, list):
      raise CloudflareError("Cloudflare DNS lookup returned an invalid result")
    return [
      item["id"]
      for item in result
      if isinstance(item, dict)
      and str(item.get("name", "")).lower() == hostname.lower()
      and item.get("content") == content
      and isinstance(item.get("id"), str)
      and RESOURCE_ID.fullmatch(item["id"])
    ]

  def delete_dns(self, record_id: str) -> None:
    self.call("DELETE", f"/zones/{self.zone_id}/dns_records/{record_id}", allow_missing=True)

  def delete_tunnel(self, tunnel_id: str) -> None:
    self.call("DELETE", f"/accounts/{self.account_id}/cfd_tunnel/{tunnel_id}", allow_missing=True)


def write_private(path: Path, value: str) -> None:
  descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
  try:
    with os.fdopen(descriptor, "w", encoding="utf-8", closefd=False) as handle:
      handle.write(value)
      handle.flush()
      os.fsync(handle.fileno())
  finally:
    os.close(descriptor)


def persist_state(output_dir: Path, state: dict) -> None:
  state_path = output_dir / STATE_FILE
  temporary = output_dir / f".{STATE_FILE}.{secrets.token_hex(8)}"
  try:
    write_private(temporary, json.dumps(state, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, state_path)
    directory = os.open(output_dir, os.O_RDONLY | os.O_DIRECTORY)
    try:
      os.fsync(directory)
    finally:
      os.close(directory)
  finally:
    temporary.unlink(missing_ok=True)


def retry_call(operation: Callable, retries: int):
  last_error = None
  for attempt in range(retries):
    try:
      return operation()
    except CloudflareError as exc:
      last_error = exc
      if attempt + 1 < retries:
        time.sleep(attempt + 1)
  raise last_error or CloudflareError("Cloudflare cleanup operation failed")


def cleanup_allocations(client: CloudflareClient, allocations: list[dict], retries: int = 4) -> list[str]:
  failures = []
  for allocation in reversed(allocations):
    record_id = allocation.get("dnsRecordId")
    record_ids = [record_id] if record_id else []
    if not record_ids and allocation.get("hostname") and allocation.get("id"):
      try:
        record_ids = retry_call(
          lambda: client.find_dns_record_ids(allocation["hostname"], allocation["id"]),
          retries,
        )
      except CloudflareError as exc:
        failures.append(str(exc))
    for discovered_id in record_ids:
      try:
        retry_call(lambda record=discovered_id: client.delete_dns(record), retries)
      except CloudflareError as exc:
        failures.append(str(exc))
  for allocation in reversed(allocations):
    tunnel_id = allocation.get("id")
    tunnel_ids = [tunnel_id] if tunnel_id else []
    if not tunnel_ids and allocation.get("name"):
      try:
        tunnel_ids = retry_call(lambda: client.find_tunnel_ids(allocation["name"]), retries)
      except CloudflareError as exc:
        failures.append(str(exc))
    for discovered_id in tunnel_ids:
      try:
        retry_call(lambda tunnel=discovered_id: client.delete_tunnel(tunnel), retries)
      except CloudflareError as exc:
        failures.append(str(exc))
  return failures


def allocate(
  client: CloudflareClient,
  output_dir: Path,
  count: int,
  prefix: str,
  suffix_factory: Callable[[], str] = lambda: secrets.token_hex(4),
) -> dict:
  if count < 1 or count > 10:
    raise CloudflareError("ephemeral tunnel count must be between 1 and 10")
  if not re.fullmatch(r"[a-z0-9-]+", prefix) or len(prefix) > 40:
    raise CloudflareError("ephemeral tunnel prefix is invalid")
  output_dir.mkdir(mode=0o700, parents=False, exist_ok=False)
  allocations: list[dict] = []
  state = {
    "schemaVersion": 1,
    "accountId": client.account_id,
    "zoneId": client.zone_id,
    "baseDomain": client.base_domain,
    "tunnels": allocations,
  }
  persist_state(output_dir, state)
  try:
    for index in range(1, count + 1):
      name = f"{prefix}-{index}-{suffix_factory()}"
      if len(name) > 63:
        raise CloudflareError("generated tunnel name exceeds one DNS label")
      hostname = f"{name}.{client.base_domain}"
      allocation = {"name": name, "hostname": hostname, "nodeIndex": index}
      allocations.append(allocation)
      persist_state(output_dir, state)
      tunnel_id, token = client.create_tunnel(name)
      allocation["id"] = tunnel_id
      persist_state(output_dir, state)
      allocation["dnsRecordId"] = client.create_dns(hostname, tunnel_id)
      persist_state(output_dir, state)
      token_name = f"node-{index}.token"
      write_private(output_dir / token_name, token)
      allocation["tokenFile"] = token_name
      persist_state(output_dir, state)
    return state
  except Exception as exc:
    failures = cleanup_allocations(client, allocations)
    for path in output_dir.glob("*.token"):
      path.unlink(missing_ok=True)
    if not failures:
      (output_dir / STATE_FILE).unlink(missing_ok=True)
    else:
      raise CloudflareError(
        f"allocation failed and cleanup left {len(failures)} remote resource failure(s)"
      ) from exc
    raise


def load_state(path: Path, expected_run_prefix: str | None = None) -> dict:
  if path.is_symlink() or not path.is_file():
    raise CloudflareError("ephemeral tunnel state is not a regular file")
  mode = stat.S_IMODE(path.stat().st_mode)
  if mode & 0o077:
    raise CloudflareError("ephemeral tunnel state is accessible outside its owner")
  state = json.loads(path.read_text(encoding="utf-8"))
  if not isinstance(state, dict) or state.get("schemaVersion") != 1 or not isinstance(state.get("tunnels"), list):
    raise CloudflareError("ephemeral tunnel state has an unsupported shape")
  if set(state) != {"schemaVersion", "accountId", "zoneId", "baseDomain", "tunnels"}:
    raise CloudflareError("ephemeral tunnel state contains unexpected fields")
  for key in ("accountId", "zoneId"):
    if not isinstance(state.get(key), str) or not RESOURCE_ID.fullmatch(state[key]):
      raise CloudflareError(f"ephemeral tunnel state has an invalid {key}")
  base_domain = state.get("baseDomain")
  if not isinstance(base_domain, str) or not re.fullmatch(r"[a-z0-9.-]+", base_domain) or "." not in base_domain:
    raise CloudflareError("ephemeral tunnel state has an invalid baseDomain")
  if len(state["tunnels"]) > 10:
    raise CloudflareError("ephemeral tunnel state contains too many tunnels")
  seen_indexes = set()
  expected_name = None
  if expected_run_prefix is not None:
    if not RUN_PREFIX.fullmatch(expected_run_prefix):
      raise CloudflareError("ephemeral cleanup run prefix is invalid")
    expected_name = re.compile(
      rf"{re.escape(expected_run_prefix)}-(?P<index>[1-3])-[0-9a-f]{{8}}"
    )
  for tunnel in state["tunnels"]:
    if not isinstance(tunnel, dict) or not set(tunnel) <= {
      "id", "name", "hostname", "nodeIndex", "dnsRecordId", "tokenFile"
    }:
      raise CloudflareError("ephemeral tunnel state contains an invalid tunnel record")
    tunnel_id = tunnel.get("id")
    name = tunnel.get("name")
    node_index = tunnel.get("nodeIndex")
    hostname = tunnel.get("hostname")
    if tunnel_id is not None and (
      not isinstance(tunnel_id, str) or not RESOURCE_ID.fullmatch(tunnel_id)
    ):
      raise CloudflareError("ephemeral tunnel state contains an invalid tunnel id")
    if name is not None and (
      not isinstance(name, str) or not re.fullmatch(r"[a-z0-9-]{1,63}", name)
    ):
      raise CloudflareError("ephemeral tunnel state contains an invalid tunnel name")
    if tunnel_id is None and name is None:
      raise CloudflareError("ephemeral tunnel state cannot identify its tunnel")
    if not isinstance(node_index, int) or isinstance(node_index, bool) or not 1 <= node_index <= 10:
      raise CloudflareError("ephemeral tunnel state contains an invalid node index")
    if node_index in seen_indexes:
      raise CloudflareError("ephemeral tunnel state contains duplicate node indexes")
    seen_indexes.add(node_index)
    if not isinstance(hostname, str) or not hostname.endswith(f".{base_domain}"):
      raise CloudflareError("ephemeral tunnel state contains an invalid hostname")
    if name is not None and hostname != f"{name}.{base_domain}":
      raise CloudflareError("ephemeral tunnel state hostname does not match its tunnel name")
    if expected_name is not None:
      match = expected_name.fullmatch(str(name or ""))
      if match is None or int(match.group("index")) != node_index:
        raise CloudflareError("ephemeral tunnel state does not match the requested run prefix")
    dns_record_id = tunnel.get("dnsRecordId")
    if dns_record_id is not None and (
      not isinstance(dns_record_id, str) or not RESOURCE_ID.fullmatch(dns_record_id)
    ):
      raise CloudflareError("ephemeral tunnel state contains an invalid DNS record id")
    token_file = tunnel.get("tokenFile")
    if token_file is not None and token_file != f"node-{node_index}.token":
      raise CloudflareError("ephemeral tunnel state contains an invalid token file")
  return state


def discover_run_allocations(client: CloudflareClient, prefix: str) -> list[dict]:
  if not RUN_PREFIX.fullmatch(prefix):
    raise CloudflareError("ephemeral cleanup run prefix is invalid")
  expected_name = re.compile(rf"{re.escape(prefix)}-(?P<index>[1-3])-[0-9a-f]{{8}}")
  tunnels = client.find_run_tunnels(prefix)
  dns_records = client.find_run_dns_records(prefix)
  if len(tunnels) > 3 or len(dns_records) > 3:
    raise CloudflareError("Cloudflare run lookup returned more than three matches")
  allocations = {}
  for tunnel in tunnels:
    if not isinstance(tunnel, dict):
      raise CloudflareError("Cloudflare run tunnel lookup returned an invalid tunnel")
    tunnel_id = tunnel.get("id")
    name = tunnel.get("name")
    match = expected_name.fullmatch(str(name or ""))
    if match is None or not isinstance(tunnel_id, str) or not RESOURCE_ID.fullmatch(tunnel_id):
      raise CloudflareError("Cloudflare run tunnel lookup returned an unexpected match")
    if tunnel.get("config_src") not in (None, "local"):
      raise CloudflareError("Cloudflare run tunnel has an unexpected configuration source")
    node_index = int(match.group("index"))
    if node_index in allocations:
      raise CloudflareError("Cloudflare run tunnel lookup returned a duplicate node index")
    allocations[node_index] = {
      "id": tunnel_id,
      "name": name,
      "hostname": f"{name}.{client.base_domain}",
      "nodeIndex": node_index,
    }
  expected_hostname = re.compile(
    rf"(?P<name>{re.escape(prefix)}-(?P<index>[1-3])-[0-9a-f]{{8}})\."
    rf"{re.escape(client.base_domain)}"
  )
  expected_content = re.compile(rf"(?P<id>{RESOURCE_ID.pattern})\.cfargotunnel\.com")
  for record in dns_records:
    if not isinstance(record, dict):
      raise CloudflareError("Cloudflare run DNS lookup returned an invalid record")
    record_id = record.get("id")
    hostname = str(record.get("name") or "").lower()
    hostname_match = expected_hostname.fullmatch(hostname)
    content_match = expected_content.fullmatch(str(record.get("content") or ""))
    if (
      hostname_match is None
      or content_match is None
      or not isinstance(record_id, str)
      or not RESOURCE_ID.fullmatch(record_id)
    ):
      raise CloudflareError("Cloudflare run DNS lookup returned an unexpected match")
    node_index = int(hostname_match.group("index"))
    name = hostname_match.group("name")
    tunnel_id = content_match.group("id")
    existing = allocations.get(node_index)
    if existing is None:
      allocations[node_index] = {
        "name": name,
        "hostname": hostname,
        "nodeIndex": node_index,
        "dnsRecordId": record_id,
      }
    elif (
      existing["name"] != name
      or existing.get("id") != tunnel_id
      or "dnsRecordId" in existing
    ):
      raise CloudflareError("Cloudflare run DNS lookup conflicts with its tunnel")
    else:
      existing["dnsRecordId"] = record_id
  return [allocations[index] for index in sorted(allocations)]


def cleanup_run_prefix(client: CloudflareClient, prefix: str, retries: int = 4) -> int:
  allocations = discover_run_allocations(client, prefix)
  failures = cleanup_allocations(client, allocations, retries=retries)
  if failures:
    raise CloudflareError(f"ephemeral run cleanup had {len(failures)} failure(s)")
  if discover_run_allocations(client, prefix):
    raise CloudflareError("ephemeral run cleanup left matching tunnels")
  return len(allocations)


def cleanup_state_allocations(
  client: CloudflareClient,
  state: dict,
  expected_run_prefix: str | None = None,
  retries: int = 4,
) -> int:
  if expected_run_prefix is not None:
    # Downloaded evidence is untrusted data. Its IDs never drive deletion.
    return cleanup_run_prefix(client, expected_run_prefix, retries=retries)
  failures = cleanup_allocations(client, state["tunnels"], retries=retries)
  if failures:
    raise CloudflareError(f"ephemeral cleanup had {len(failures)} failure(s)")
  return len(state["tunnels"])


def client_from_environment(state: dict | None = None) -> CloudflareClient:
  for environment_key, state_key in (
    ("CF_ACCOUNT_ID", "accountId"),
    ("CF_ZONE_ID", "zoneId"),
    ("CF_BASE_DOMAIN", "baseDomain"),
  ):
    environment_value = os.environ.get(environment_key)
    state_value = (state or {}).get(state_key)
    if environment_value and state_value and environment_value.strip(".").lower() != state_value.strip(".").lower():
      raise CloudflareError(f"{environment_key} does not match the allocation state")
  return CloudflareClient(
    account_id=os.environ.get("CF_ACCOUNT_ID") or (state or {}).get("accountId", ""),
    zone_id=os.environ.get("CF_ZONE_ID") or (state or {}).get("zoneId", ""),
    api_token=os.environ.get("CF_API_TOKEN", ""),
    base_domain=os.environ.get("CF_BASE_DOMAIN") or (state or {}).get("baseDomain", ""),
  )


def main() -> None:
  parser = argparse.ArgumentParser()
  subparsers = parser.add_subparsers(dest="command", required=True)
  create = subparsers.add_parser("create")
  create.add_argument("--output-dir", required=True, type=Path)
  create.add_argument("--count", type=int, default=3)
  create.add_argument("--prefix", required=True)
  cleanup = subparsers.add_parser("cleanup")
  cleanup.add_argument("--state", required=True, type=Path)
  cleanup.add_argument("--expected-run-prefix")
  cleanup_prefix = subparsers.add_parser("cleanup-prefix")
  cleanup_prefix.add_argument("--prefix", required=True)
  args = parser.parse_args()

  try:
    if args.command == "create":
      state = allocate(client_from_environment(), args.output_dir, args.count, args.prefix)
      print("\n".join(tunnel["hostname"] for tunnel in state["tunnels"]))
      return
    if args.command == "cleanup-prefix":
      count = cleanup_run_prefix(client_from_environment(), args.prefix)
      print(f"cleaned {count} ephemeral Cloudflare tunnels for {args.prefix}")
      return
    state = load_state(args.state, expected_run_prefix=args.expected_run_prefix)
    count = cleanup_state_allocations(
      client_from_environment(state),
      state,
      expected_run_prefix=args.expected_run_prefix,
    )
    for tunnel in state["tunnels"]:
      token_file = tunnel.get("tokenFile")
      if token_file:
        (args.state.parent / token_file).unlink(missing_ok=True)
    args.state.unlink()
    print(f"cleaned {count} ephemeral Cloudflare tunnels")
  except (CloudflareError, OSError, json.JSONDecodeError) as exc:
    print(f"ephemeral tunnel error: {exc}", file=sys.stderr)
    raise SystemExit(1) from exc


if __name__ == "__main__":
  main()
