#!/usr/bin/env python3
"""Generate the deterministic release-context SHA-256 manifest."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "source" / "manifest.sha256"
EXCLUDED_PARTS = {".git", ".playwright", "__pycache__"}
EXCLUDED_SOURCE_SUFFIXES = (".cdx.json", ".spdx.json", ".tar.gz")


def included_files() -> list[Path]:
  files = []
  for path in ROOT.rglob("*"):
    if not path.is_file():
      continue
    relative = path.relative_to(ROOT)
    if EXCLUDED_PARTS.intersection(relative.parts):
      continue
    if path.suffix in {".pyc", ".pyo"}:
      continue
    if relative == OUTPUT.relative_to(ROOT) or path.name.endswith(".log"):
      continue
    if relative.parts[0] == "source" and path.name.endswith(EXCLUDED_SOURCE_SUFFIXES):
      continue
    files.append(relative)
  return sorted(files, key=lambda path: path.as_posix())


def render_manifest() -> str:
  lines = []
  for relative in included_files():
    digest = hashlib.sha256((ROOT / relative).read_bytes()).hexdigest()
    lines.append(f"{digest}  {relative.as_posix()}\n")
  return "".join(lines)


def main() -> None:
  parser = argparse.ArgumentParser()
  parser.add_argument("--check", action="store_true", help="fail unless the manifest matches the build inventory")
  args = parser.parse_args()
  rendered = render_manifest()
  if args.check:
    existing = OUTPUT.read_text(encoding="utf-8") if OUTPUT.is_file() else ""
    if existing != rendered:
      print("source manifest does not match the current build inventory", file=sys.stderr)
      raise SystemExit(1)
    print(f"verified {len(rendered.splitlines())} source hashes")
    return
  OUTPUT.write_text(rendered, encoding="utf-8")
  print(f"wrote {len(rendered.splitlines())} hashes to {OUTPUT.relative_to(ROOT)}")


if __name__ == "__main__":
  main()
