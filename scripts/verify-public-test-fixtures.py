#!/usr/bin/env python3
"""Verify that every checked-in private key is an exact known public test fixture."""

from __future__ import annotations

import hashlib
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
ALLOWLIST = ROOT / "source" / "public-test-fixtures.sha256"
FIXTURE_PREFIX = "engine/pkg/security/securitytest/test_certs/"
PRIVATE_KEY = re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")
TOKEN_PATTERNS = {
  "GitHub token": re.compile(rb"\bgh[pousr]_[A-Za-z0-9]{20,}\b"),
  "Cloudflare API token": re.compile(rb"\bcfut_[A-Za-z0-9_-]{20,}\b"),
}


def fail(message: str) -> None:
  print(f"fixture-scan error: {message}", file=sys.stderr)
  raise SystemExit(1)


def sha256(path: Path) -> str:
  return hashlib.sha256(path.read_bytes()).hexdigest()


def load_allowlist() -> dict[str, str]:
  allowed: dict[str, str] = {}
  for line in ALLOWLIST.read_text(encoding="utf-8").splitlines():
    digest, path = line.split(maxsplit=1)
    if not path.startswith(FIXTURE_PREFIX):
      fail(f"allowlist path is outside the public fixture directory: {path}")
    allowed[path] = digest
  return allowed


def main() -> None:
  allowed = load_allowlist()
  for relative, expected in allowed.items():
    path = ROOT / relative
    if not path.is_file() or sha256(path) != expected:
      fail(f"public fixture hash mismatch: {relative}")

  private_keys: set[str] = set()
  for path in ROOT.rglob("*"):
    if not path.is_file() or ".git" in path.parts:
      continue
    try:
      content = path.read_bytes()
    except OSError as error:
      fail(f"cannot scan {path.relative_to(ROOT)}: {error}")
    relative = path.relative_to(ROOT).as_posix()
    if PRIVATE_KEY.search(content):
      private_keys.add(relative)
    for label, pattern in TOKEN_PATTERNS.items():
      if pattern.search(content):
        fail(f"{label} found in repository file: {relative}")

  unapproved = sorted(private_keys.difference(allowed))
  if unapproved:
    fail(f"unapproved private key found: {unapproved[0]}")
  print(f"verified {len(private_keys)} public private-key test fixtures and no token patterns")


if __name__ == "__main__":
  main()
