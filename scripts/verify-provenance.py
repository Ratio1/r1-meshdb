#!/usr/bin/env python3
"""Verify hashes and metadata claimed by source/provenance.json."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
PROVENANCE = ROOT / "source" / "provenance.json"
OVERRIDES = ROOT / "source" / "ratio1-engine-overrides.json"
EXPECTED_MODIFIED_FILES = {
  "engine/pkg/cli/cli.go",
  "engine/pkg/ui/ui.go",
  "engine/pkg/util/ctxutil/context.go",
}
EXPECTED_REMOVED_FILES = {"engine/pkg/util/ctxutil/context_abi_pre1_20.go"}
EXPECTED_ADDED_FILES = {
  "engine/pkg/util/ctxutil/context_go1.20_test.go",
  "engine/pkg/util/goschedstats/runtime_go1.26.go",
  "engine/pkg/util/goschedstats/runtime_go1.26_test.go",
}
EXPECTED_SECURITY_BACKPORTS = {"GO-2026-4518", "GO-2026-5004"}
EXPECTED_COMPATIBILITY_BACKPORTS = {"google-api-grpc-credentials-options"}


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


def check_build_input(build_inputs: dict, dockerfile: str, build_info: str) -> None:
  go_builder = build_inputs.get("goBuilder", "")
  runtime_image = build_inputs.get("runtime", "")
  if not re.fullmatch(r"golang:[^@]+@sha256:[0-9a-f]{64}", go_builder):
    fail("Go builder is not tag-and-digest pinned")
  if not re.fullmatch(r"debian:[^@]+@sha256:[0-9a-f]{64}", runtime_image):
    fail("runtime image is not tag-and-digest pinned")
  if go_builder not in dockerfile:
    fail("Dockerfile Go builder differs from provenance")
  if runtime_image not in dockerfile:
    fail("Dockerfile runtime image differs from provenance")

  cloudflared = build_inputs.get("cloudflared", {})
  source_archive = cloudflared.get("sourceArchiveUrl", "")
  source_hash = cloudflared.get("sourceArchiveSha256", "")
  binary_hash = cloudflared.get("binarySha256", "")
  commit = cloudflared.get("commit", "")
  if source_archive != f"https://github.com/cloudflare/cloudflared/archive/{commit}.tar.gz":
    fail("Cloudflared source archive does not use the exact provenance commit")
  if not re.fullmatch(r"[0-9a-f]{64}", source_hash):
    fail("Cloudflared source archive SHA-256 is invalid")
  if not re.fullmatch(r"[0-9a-f]{64}", binary_hash):
    fail("Cloudflared binary SHA-256 is invalid")
  for value, label in (
    (source_archive, "source archive"),
    (source_hash, "source archive hash"),
    (binary_hash, "binary hash"),
    (commit, "commit"),
  ):
    if value not in dockerfile:
      fail(f"Dockerfile does not enforce the Cloudflared {label}")
  if re.search(r"FROM\s+cloudflare/cloudflared", dockerfile, re.IGNORECASE):
    fail("Dockerfile must build Cloudflared from pinned source")
  if "/cloudflared: go1.26.5" not in build_info:
    fail("Cloudflared was not built with the pinned Go toolchain")
  if "\tdep\tgoogle.golang.org/grpc\tv1.83.0\t" not in build_info:
    fail("Cloudflared does not embed the reviewed gRPC version")


def check_engine_dependency_snapshot(upstream: dict) -> None:
  snapshot = upstream.get("dependencySnapshot", {})
  expected = {
    "goModSha256": ROOT / "engine" / "go.mod",
    "goSumSha256": ROOT / "engine" / "go.sum",
    "vendorModulesSha256": ROOT / "engine" / "vendor" / "modules.txt",
  }
  if snapshot.get("goVersion") != "1.25.0":
    fail("engine dependency snapshot must use Go 1.25 language semantics")
  for key, path in expected.items():
    if snapshot.get(key) != file_sha256(path):
      fail(f"engine dependency snapshot differs: {key}")


def check_engine_overrides(upstream_commit: str, patch_record: str, upstream_root: Path | None) -> None:
  overrides = json.loads(OVERRIDES.read_text(encoding="utf-8"))
  if overrides.get("upstreamCommit") != upstream_commit:
    fail("engine override record does not use the provenance upstream commit")
  records = overrides.get("modifiedUpstreamFiles")
  if not isinstance(records, list):
    fail("modified upstream file records must be a list")
  paths = {record.get("path") for record in records if isinstance(record, dict)}
  if paths != EXPECTED_MODIFIED_FILES or len(records) != len(EXPECTED_MODIFIED_FILES):
    fail(f"engine override set changed: {sorted(path for path in paths if path)}")
  for record in records:
    path = record.get("path", "")
    upstream_hash = record.get("upstreamSha256", "")
    distributed_hash = record.get("distributedSha256", "")
    change_class = record.get("changeClass")
    if change_class not in {"comments-only", "go-toolchain-compatibility"}:
      fail(f"engine override has an invalid change class: {path}")
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
      if change_class == "comments-only" and (
        without_go_comments(upstream_path.read_bytes()) != without_go_comments(target.read_bytes())
      ):
        fail(f"engine override changes more than Go comments: {path}")

  removed = overrides.get("removedUpstreamFiles")
  removed_paths = {record.get("path") for record in removed if isinstance(record, dict)}
  if removed_paths != EXPECTED_REMOVED_FILES or len(removed) != len(EXPECTED_REMOVED_FILES):
    fail("removed upstream file set changed")
  for record in removed:
    path = record["path"]
    if (ROOT / path).exists() or not record.get("reason"):
      fail(f"removed upstream file is present or unexplained: {path}")
    if path not in patch_record:
      fail(f"removed upstream file is absent from RATIO1_PATCHES.md: {path}")
    if upstream_root is not None:
      upstream_path = upstream_root / path.removeprefix("engine/")
      if not upstream_path.is_file() or file_sha256(upstream_path) != record.get("upstreamSha256"):
        fail(f"removed upstream file hash differs: {path}")

  added = overrides.get("ratio1AddedFiles")
  added_paths = {record.get("path") for record in added if isinstance(record, dict)}
  if added_paths != EXPECTED_ADDED_FILES or len(added) != len(EXPECTED_ADDED_FILES):
    fail("Ratio1-added engine file set changed")
  for record in added:
    path = record["path"]
    target = ROOT / path
    if not target.is_file() or file_sha256(target) != record.get("sha256"):
      fail(f"Ratio1-added engine file hash differs: {path}")
    if path not in patch_record:
      fail(f"Ratio1-added engine file is absent from RATIO1_PATCHES.md: {path}")

  dependency = overrides.get("dependencySnapshot", {})
  distributed = dependency.get("distributed", {})
  current_dependency_files = {
    "goModSha256": ROOT / "engine" / "go.mod",
    "goSumSha256": ROOT / "engine" / "go.sum",
    "vendorModulesSha256": ROOT / "engine" / "vendor" / "modules.txt",
  }
  for key, path in current_dependency_files.items():
    if distributed.get(key) != file_sha256(path):
      fail(f"distributed dependency snapshot differs: {key}")
  if not dependency.get("reason") or "dependency snapshot" not in patch_record.lower():
    fail("dependency snapshot is not explained in RATIO1_PATCHES.md")
  if upstream_root is not None:
    upstream = dependency.get("upstream", {})
    for key, path in list(current_dependency_files.items())[:2]:
      upstream_path = upstream_root / path.relative_to(ROOT / "engine")
      if not upstream_path.is_file() or upstream.get(key) != file_sha256(upstream_path):
        fail(f"upstream dependency snapshot differs: {key}")
  baseline = dependency.get("sourceBaseline", {})
  baseline_commit = baseline.get("commit", "")
  if not re.fullmatch(r"[0-9a-f]{40}", baseline_commit):
    fail("source dependency baseline commit is invalid")
  git_probe = subprocess.run(
    ["git", "rev-parse", "--is-inside-work-tree"],
    cwd=ROOT,
    check=False,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
  )
  if git_probe.returncode == 0:
    result = subprocess.run(
      ["git", "show", f"{baseline_commit}:engine/vendor/modules.txt"],
      cwd=ROOT,
      check=True,
      stdout=subprocess.PIPE,
    )
    if baseline.get("vendorModulesSha256") != hashlib.sha256(result.stdout).hexdigest():
      fail("source baseline vendor module snapshot differs")

  backports = overrides.get("securityBackports")
  advisories = {record.get("advisory") for record in backports if isinstance(record, dict)}
  if advisories != EXPECTED_SECURITY_BACKPORTS or len(backports) != len(EXPECTED_SECURITY_BACKPORTS):
    fail("security backport set changed")
  for backport in backports:
    if not backport.get("module") or not backport.get("source"):
      fail(f"security backport metadata is incomplete: {backport.get('advisory')}")
    if backport["advisory"] not in patch_record:
      fail(f"security backport is absent from RATIO1_PATCHES.md: {backport['advisory']}")
    files = backport.get("files")
    if not files:
      fail(f"security backport has no files: {backport['advisory']}")
    for record in files:
      target = ROOT / record.get("path", "")
      if not target.is_file() or file_sha256(target) != record.get("sha256"):
        fail(f"security backport file hash differs: {record.get('path')}")

  compatibility_backports = overrides.get("dependencyCompatibilityBackports")
  backport_ids = {
    record.get("id") for record in compatibility_backports if isinstance(record, dict)
  }
  if backport_ids != EXPECTED_COMPATIBILITY_BACKPORTS or (
    len(compatibility_backports) != len(EXPECTED_COMPATIBILITY_BACKPORTS)
  ):
    fail("dependency compatibility backport set changed")
  for backport in compatibility_backports:
    if not backport.get("module") or not backport.get("source") or not backport.get("reason"):
      fail(f"dependency compatibility backport metadata is incomplete: {backport.get('id')}")
    if backport["id"] not in patch_record:
      fail(f"dependency compatibility backport is absent from RATIO1_PATCHES.md: {backport['id']}")
    files = backport.get("files")
    if not files:
      fail(f"dependency compatibility backport has no files: {backport['id']}")
    for record in files:
      target = ROOT / record.get("path", "")
      if not target.is_file() or file_sha256(target) != record.get("sha256"):
        fail(f"dependency compatibility backport file hash differs: {record.get('path')}")


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
    provenance.get("buildInputs", {}),
    (ROOT / "Dockerfile").read_text(encoding="utf-8"),
    (ROOT / "source" / "cloudflared-buildinfo.txt").read_text(encoding="utf-8"),
  )
  check_engine_dependency_snapshot(provenance.get("upstream", {}))
  check_engine_overrides(
    provenance.get("upstream", {}).get("commit", ""),
    (ROOT / "RATIO1_PATCHES.md").read_text(encoding="utf-8"),
    args.upstream_root.resolve() if args.upstream_root else None,
  )
  print(f"provenance verified: {len(actual_hashes)} native trees and pinned runtime inputs")


if __name__ == "__main__":
  main()
