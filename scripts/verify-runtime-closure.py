#!/usr/bin/env python3
"""Verify that the checked-in engine is exactly the OSS binary source closure."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "engine"
EXPECTED = ROOT / "source" / "runtime-files.txt"
SOURCE_KEYS = (
  "GoFiles", "CgoFiles", "CFiles", "CXXFiles", "MFiles", "HFiles",
  "FFiles", "SFiles", "SwigFiles", "SwigCXXFiles", "SysoFiles",
  "EmbedFiles",
)
MODULE_PREFIX = "github.com/cockroachdb/cockroach"
SUPPLEMENTAL_PACKAGE_TREES = {
  "github.com/knz/go-libedit/unix": ("src",),
}


def fail(message: str) -> None:
  print(f"runtime-closure error: {message}", file=sys.stderr)
  raise SystemExit(1)


def go_list() -> list[dict]:
  environment = {
    **os.environ,
    "GOPROXY": "off",
    "GOSUMDB": "off",
    "GOFLAGS": "-buildvcs=false",
  }
  result = subprocess.run(
    ["go", "list", "-mod=vendor", "-deps", "-json", "./pkg/cmd/cockroach-oss"],
    cwd=ENGINE,
    env=environment,
    check=True,
    text=True,
    stdout=subprocess.PIPE,
  )
  decoder = json.JSONDecoder()
  index = 0
  packages = []
  while index < len(result.stdout):
    while index < len(result.stdout) and result.stdout[index].isspace():
      index += 1
    if index >= len(result.stdout):
      break
    package, index = decoder.raw_decode(result.stdout, index)
    packages.append(package)
  return packages


def closure(packages: list[dict]) -> list[str]:
  files: set[str] = set()
  for package in packages:
    import_path = package.get("ImportPath", "")
    if import_path.startswith(f"{MODULE_PREFIX}/pkg/ccl"):
      fail(f"OSS binary imports CCL package {import_path}")
    directory = Path(package.get("Dir", ""))
    try:
      relative_directory = directory.resolve().relative_to(ENGINE.resolve())
    except (ValueError, FileNotFoundError):
      continue
    for key in SOURCE_KEYS:
      for name in package.get(key, []):
        relative = (relative_directory / name).as_posix()
        if "/zcgo_flags" in relative and not relative.endswith("/zcgo_flags_extra.go"):
          continue
        if not (ENGINE / relative).is_file():
          fail(f"go list selected missing source file {relative}")
        files.add(relative)
    for tree_name in SUPPLEMENTAL_PACKAGE_TREES.get(import_path, ()):
      tree = directory / tree_name
      if not tree.is_dir():
        fail(f"selected package asset tree is missing: {import_path}/{tree_name}")
      for path in tree.rglob("*"):
        if path.is_file():
          files.add(path.resolve().relative_to(ENGINE.resolve()).as_posix())
  return sorted(files)


def main() -> None:
  parser = argparse.ArgumentParser()
  parser.add_argument("--write", action="store_true")
  args = parser.parse_args()
  rendered = "\n".join(closure(go_list())) + "\n"
  if args.write:
    EXPECTED.write_text(rendered, encoding="utf-8")
    print(f"wrote runtime closure to {EXPECTED.relative_to(ROOT)}")
    return
  if not EXPECTED.is_file() or EXPECTED.read_text(encoding="utf-8") != rendered:
    fail("source/runtime-files.txt does not match the OSS import closure")
  print(f"verified {len(rendered.splitlines())} OSS runtime source files")


if __name__ == "__main__":
  main()
