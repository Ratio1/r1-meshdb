#!/usr/bin/env python3
# Copyright 2026 Ratio1
# Licensed under the Apache License, Version 2.0. See LICENSE.

"""Compare retained generated source with an exact generated upstream tree."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
PROVENANCE = ROOT / "source" / "provenance.json"
GENERATED = ROOT / "source" / "generated-files.txt"


def fail(message: str) -> None:
  print(f"generated provenance error: {message}", file=sys.stderr)
  raise SystemExit(1)


def sha256(path: Path) -> str:
  digest = hashlib.sha256()
  with path.open("rb") as handle:
    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
      digest.update(chunk)
  return digest.hexdigest()


def main() -> None:
  parser = argparse.ArgumentParser()
  parser.add_argument("--upstream-root", required=True, type=Path)
  args = parser.parse_args()

  upstream_root = args.upstream_root.resolve()
  provenance = json.loads(PROVENANCE.read_text(encoding="utf-8"))
  expected_commit = provenance["upstream"]["commit"]
  revision = subprocess.run(
    ["git", "rev-parse", "HEAD"],
    cwd=upstream_root,
    check=True,
    text=True,
    stdout=subprocess.PIPE,
  ).stdout.strip()
  if revision != expected_commit:
    fail(f"upstream checkout is {revision}, expected {expected_commit}")

  declared = [line.strip() for line in GENERATED.read_text(encoding="utf-8").splitlines() if line.strip()]
  if declared != sorted(set(declared)):
    fail("generated file inventory must be sorted and contain no duplicates")

  compared = 0
  vendor_generated = []
  for relative in declared:
    if relative.startswith("vendor/"):
      vendor_generated.append(relative)
      continue
    if not relative.startswith("pkg/"):
      fail(f"unexpected generated path boundary: {relative}")
    local_path = ROOT / "engine" / relative
    upstream_path = upstream_root / relative
    if not local_path.is_file():
      fail(f"retained generated file is missing: {relative}")
    if not upstream_path.is_file():
      fail(f"upstream generator did not produce: {relative}")
    if sha256(local_path) != sha256(upstream_path):
      fail(f"generated output differs from exact upstream generator: {relative}")
    compared += 1

  if vendor_generated != ["vendor/github.com/knz/go-libedit/unix/zcgo_flags_extra.go"]:
    fail(f"unexpected generated vendor inventory: {vendor_generated}")
  if compared < 150:
    fail(f"generated output comparison was unexpectedly small: {compared}")
  print(f"generated provenance verified: {compared} exact upstream outputs")


if __name__ == "__main__":
  main()
