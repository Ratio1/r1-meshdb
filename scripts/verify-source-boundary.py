#!/usr/bin/env python3
"""Reject enterprise source and unaudited release files from the distribution."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "engine"
FORBIDDEN_PREFIXES = (
  "engine/pkg/ccl/",
  "engine/pkg/ui/distccl/",
  "engine/pkg/ui/workspaces/db-console/ccl/",
)
FORBIDDEN_SOURCE_MARKERS = (
  b"Cockroach Community License",
  b"github.com/cockroachdb/cockroach/pkg/ccl",
  b"pkg/ui/distccl",
)
def fail(message: str) -> None:
  print(f"source-boundary error: {message}", file=sys.stderr)
  raise SystemExit(1)


def normalized(path: Path) -> str:
  return path.as_posix().replace("\\", "/")


def is_forbidden_path(path: str) -> bool:
  return any(path == prefix.rstrip("/") or path.startswith(prefix) for prefix in FORBIDDEN_PREFIXES)


def is_engine_file(path: str) -> bool:
  return path.startswith("engine/")


def scan_source(path: Path, display_path: str) -> None:
  content = path.read_bytes()
  for marker in FORBIDDEN_SOURCE_MARKERS:
    if marker.lower() in content.lower():
      fail(f"enterprise source marker found in {display_path}: {marker.decode()}")


def scan_worktree() -> None:
  if not ENGINE.is_dir():
    fail("engine source directory is missing")

  for path in ENGINE.rglob("*"):
    relative = normalized(path.relative_to(ROOT))
    if is_forbidden_path(relative):
      fail(f"forbidden enterprise implementation path exists: {relative}")
    if path.name == ".git":
      fail(f"nested Git metadata found: {relative}")
    if path.is_symlink():
      try:
        path.resolve(strict=True).relative_to(ENGINE.resolve())
      except (OSError, ValueError):
        fail(f"engine symlink escapes the source tree: {relative}")
    if path.is_file() and is_engine_file(relative):
      scan_source(path, relative)


def assert_no_untracked_release_files() -> None:
  result = subprocess.run(
    ["git", "ls-files", "--others", "--exclude-standard"],
    cwd=ROOT,
    check=True,
    text=True,
    stdout=subprocess.PIPE,
  )
  untracked = [line for line in result.stdout.splitlines() if line]
  if untracked:
    fail(f"untracked release file is not auditable: {untracked[0]}")

  tracked_engine = {
    line for line in subprocess.run(
      ["git", "ls-files", "engine"],
      cwd=ROOT,
      check=True,
      text=True,
      stdout=subprocess.PIPE,
    ).stdout.splitlines()
    if line
  }
  worktree_engine = {
    normalized(path.relative_to(ROOT))
    for path in ENGINE.rglob("*")
    if path.is_file() or path.is_symlink()
  }
  missing = sorted(worktree_engine - tracked_engine)
  if missing:
    fail(f"engine file is ignored or untracked: {missing[0]}")


def reachable_objects() -> list[tuple[str, str]]:
  result = subprocess.run(
    ["git", "rev-list", "--objects", "--all"],
    cwd=ROOT,
    check=True,
    text=True,
    stdout=subprocess.PIPE,
  )
  objects: list[tuple[str, str]] = []
  for line in result.stdout.splitlines():
    parts = line.split(" ", 1)
    if len(parts) != 2:
      continue
    object_id, path = parts
    path = path.replace("\\", "/")
    if is_forbidden_path(path):
      fail(f"reachable history contains forbidden enterprise path: {object_id} {path}")
    if is_engine_file(path):
      objects.append((object_id, path))
  return objects


def scan_history() -> None:
  objects = reachable_objects()
  if not objects:
    return

  process = subprocess.Popen(
    ["git", "cat-file", "--batch"],
    cwd=ROOT,
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
  )
  assert process.stdin is not None
  assert process.stdout is not None
  for object_id, path in objects:
    process.stdin.write(f"{object_id}\n".encode())
    process.stdin.flush()
    header = process.stdout.readline().decode().strip().split()
    if len(header) != 3:
      fail(f"could not inspect reachable object: {object_id} {path}")
    body = process.stdout.read(int(header[2]))
    process.stdout.read(1)
    if header[1] != "blob":
      continue
    for marker in FORBIDDEN_SOURCE_MARKERS:
      if marker.lower() in body.lower():
        fail(f"reachable history contains enterprise source marker: {object_id} {path}")
  process.stdin.close()
  if process.wait() != 0:
    fail("git cat-file failed while scanning history")


def scan_import_graph(engine: Path) -> None:
  environment = {
    **os.environ,
    "GOPROXY": "off",
    "GOSUMDB": "off",
    "GOFLAGS": "-buildvcs=false",
  }
  result = subprocess.run(
    ["go", "list", "-deps", "-mod=vendor", "./pkg/cmd/cockroach-oss"],
    cwd=engine,
    env=environment,
    check=True,
    text=True,
    stdout=subprocess.PIPE,
  )
  offenders = [
    package for package in result.stdout.splitlines()
    if package.startswith("github.com/cockroachdb/cockroach/pkg/ccl")
  ]
  if offenders:
    fail(f"OSS command imports enterprise packages: {offenders}")


def main() -> None:
  parser = argparse.ArgumentParser()
  parser.add_argument("--worktree-only", action="store_true")
  parser.add_argument("--check-import-graph", action="store_true")
  parser.add_argument("--engine-dir", type=Path, default=ENGINE)
  args = parser.parse_args()

  scan_worktree()
  if not args.worktree_only:
    assert_no_untracked_release_files()
    scan_history()
  if args.check_import_graph:
    scan_import_graph(args.engine_dir.resolve())
  print("source boundary verified: no enterprise implementation found")


if __name__ == "__main__":
  main()
