#!/usr/bin/env python3
"""Verify hashes and metadata claimed by source/provenance.json."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
PROVENANCE = ROOT / "source" / "provenance.json"
OVERRIDES = ROOT / "source" / "ratio1-engine-overrides.json"
EXPECTED_OVERRIDES = {
  "engine/pkg/cli/cli.go",
  "engine/pkg/ui/ui.go",
}


def fail(message: str) -> None:
  print(f"provenance error: {message}", file=sys.stderr)
  raise SystemExit(1)


def file_sha256(path: Path) -> str:
  digest = hashlib.sha256()
  with path.open("rb") as handle:
    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
      digest.update(chunk)
  return digest.hexdigest()


def without_go_comments(content: bytes) -> bytes:
  output = bytearray()
  index = 0
  state = "code"
  while index < len(content):
    current = content[index]
    following = content[index + 1] if index + 1 < len(content) else None
    if state == "code":
      if current == ord("/") and following == ord("/"):
        state = "line-comment"
        index += 2
        continue
      if current == ord("/") and following == ord("*"):
        state = "block-comment"
        index += 2
        continue
      output.append(current)
      if current == ord('"'):
        state = "string"
      elif current == ord("'"):
        state = "rune"
      elif current == ord("`"):
        state = "raw-string"
      index += 1
      continue
    if state == "line-comment":
      if current in (ord("\n"), ord("\r")):
        output.append(current)
        state = "code"
      index += 1
      continue
    if state == "block-comment":
      if current in (ord("\n"), ord("\r")):
        output.append(current)
      if current == ord("*") and following == ord("/"):
        state = "code"
        index += 2
      else:
        index += 1
      continue
    output.append(current)
    if state in ("string", "rune") and current == ord("\\"):
      if following is not None:
        output.append(following)
        index += 2
      else:
        index += 1
      continue
    if (state == "string" and current == ord('"')) or (
      state == "rune" and current == ord("'")
    ) or (state == "raw-string" and current == ord("`")):
      state = "code"
    index += 1
  if state in ("string", "rune", "raw-string", "block-comment"):
    fail(f"unterminated Go lexical state while validating overrides: {state}")
  return bytes(output)


def tree_sha256(root: Path) -> str:
  digest = hashlib.sha256()
  paths = sorted(root.rglob("*"), key=lambda path: path.relative_to(root).as_posix())
  for path in paths:
    relative = path.relative_to(root).as_posix().encode("utf-8")
    if path.is_symlink():
      target = os.readlink(path).encode("utf-8")
      try:
        path.resolve(strict=True).relative_to(root.resolve())
      except (OSError, ValueError):
        fail(f"native dependency symlink escapes its tree: {path.relative_to(ROOT)}")
      digest.update(b"L\0" + relative + b"\0" + target + b"\0")
    elif path.is_file():
      digest.update(b"F\0" + relative + b"\0" + bytes.fromhex(file_sha256(path)) + b"\0")
  return digest.hexdigest()


def check_build_input(cloudflared: dict, dockerfile: str, build_info: str) -> None:
  image = cloudflared.get("image", "")
  binary_hash = cloudflared.get("binarySha256", "")
  commit = cloudflared.get("commit", "")
  modified = cloudflared.get("vcsModified")
  if not re.fullmatch(r"cloudflare/cloudflared:[^@]+@sha256:[0-9a-f]{64}", image):
    fail("Cloudflared image is not tag-and-digest pinned")
  if not re.fullmatch(r"[0-9a-f]{64}", binary_hash):
    fail("Cloudflared binary SHA-256 is invalid")
  if image not in dockerfile:
    fail("Dockerfile Cloudflared image differs from provenance")
  if binary_hash not in dockerfile:
    fail("Dockerfile does not enforce the recorded Cloudflared binary hash")
  if f"vcs.revision={commit}" not in build_info:
    fail("Cloudflared build metadata revision differs from provenance")
  recorded_modified = "vcs.modified=true" in build_info
  if modified is not recorded_modified:
    fail("Cloudflared vcs.modified state differs from provenance")


def check_engine_overrides(upstream_commit: str, patch_record: str, upstream_root: Path | None) -> None:
  overrides = json.loads(OVERRIDES.read_text(encoding="utf-8"))
  if overrides.get("upstreamCommit") != upstream_commit:
    fail("engine override record does not use the provenance upstream commit")
  records = overrides.get("files")
  if not isinstance(records, list):
    fail("engine override record files must be a list")
  paths = {record.get("path") for record in records if isinstance(record, dict)}
  if paths != EXPECTED_OVERRIDES or len(records) != len(EXPECTED_OVERRIDES):
    fail(f"engine override set changed: {sorted(path for path in paths if path)}")
  for record in records:
    path = record.get("path", "")
    upstream_hash = record.get("upstreamSha256", "")
    distributed_hash = record.get("distributedSha256", "")
    if record.get("changeClass") != "comments-only":
      fail(f"engine override is not classified as comments-only: {path}")
    if not record.get("reason"):
      fail(f"engine override has no reason: {path}")
    if not re.fullmatch(r"[0-9a-f]{64}", upstream_hash):
      fail(f"engine override has an invalid upstream hash: {path}")
    target = ROOT / path
    if not target.is_file() or file_sha256(target) != distributed_hash:
      fail(f"engine override distributed hash differs: {path}")
    if path not in patch_record:
      fail(f"engine override is absent from RATIO1_PATCHES.md: {path}")
    if upstream_root is not None:
      upstream_path = upstream_root / path.removeprefix("engine/")
      if not upstream_path.is_file() or file_sha256(upstream_path) != upstream_hash:
        fail(f"engine override upstream hash differs: {path}")
      if without_go_comments(upstream_path.read_bytes()) != without_go_comments(target.read_bytes()):
        fail(f"engine override changes more than Go comments: {path}")


def main() -> None:
  parser = argparse.ArgumentParser()
  parser.add_argument("--print-native-hashes", action="store_true")
  parser.add_argument("--upstream-root", type=Path)
  args = parser.parse_args()

  provenance = json.loads(PROVENANCE.read_text(encoding="utf-8"))
  expected_algorithm = (
    "sha256 over sorted entries: type-byte, NUL, relative UTF-8 path, NUL, "
    "file SHA-256 bytes or symlink target, NUL"
  )
  if provenance.get("nativeTreeHashAlgorithm") != expected_algorithm:
    fail("native tree-hash algorithm is missing or changed")
  actual_hashes = {}
  for dependency in provenance.get("nativeDependencies", []):
    name = dependency.get("name", "")
    root = ROOT / "engine" / "c-deps" / name
    if not root.is_dir():
      fail(f"native dependency tree is missing: {name}")
    actual = tree_sha256(root)
    actual_hashes[name] = actual
    if not args.print_native_hashes and dependency.get("treeSha256") != actual:
      fail(f"native dependency tree hash differs for {name}: {actual}")

  if args.print_native_hashes:
    print(json.dumps(actual_hashes, indent=2, sort_keys=True))
    return

  runtime = provenance.get("runtimeLayer", {})
  if runtime.get("entrypointSha256") != file_sha256(ROOT / "entrypoint.sh"):
    fail("entrypoint hash differs from provenance")

  check_build_input(
    provenance.get("buildInputs", {}).get("cloudflared", {}),
    (ROOT / "Dockerfile").read_text(encoding="utf-8"),
    (ROOT / "source" / "cloudflared-buildinfo.txt").read_text(encoding="utf-8"),
  )
  check_engine_overrides(
    provenance.get("upstream", {}).get("commit", ""),
    (ROOT / "RATIO1_PATCHES.md").read_text(encoding="utf-8"),
    args.upstream_root.resolve() if args.upstream_root else None,
  )
  print(f"provenance verified: {len(actual_hashes)} native trees and pinned runtime inputs")


if __name__ == "__main__":
  main()
