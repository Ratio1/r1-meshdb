#!/usr/bin/env python3
"""Verify the pinned Cloudflared source build and its notice closure."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
BUILD_INFO = ROOT / "source" / "cloudflared-buildinfo.txt"
PACKAGES = ROOT / "source" / "cloudflared-compiled-packages.txt"
INVENTORY = ROOT / "source" / "cloudflared-license-inventory.csv"
LICENSE_ROOT = ROOT / "licenses" / "cloudflared"
LICENSE_NAMES = {"license", "licence", "copying", "notice", "patents"}
COMMIT = "b4f47e2ab538ab6e31d3dc6adc5489455ad446de"
EXTERNAL_LICENSES = {
  "github.com/facebookgo/grace": (
    "dependencies/github.com/facebookgo/grace/license",
    "f657f99d3fb9647db92628e96007aabb46e5f04f33e49999075aab8e250ca7ce",
  ),
}


def fail(message: str) -> None:
  print(f"cloudflared compliance error: {message}", file=sys.stderr)
  raise SystemExit(1)


def sha256(path: Path) -> str:
  return hashlib.sha256(path.read_bytes()).hexdigest()


def is_license_file(path: Path) -> bool:
  return path.name.lower().split(".", 1)[0] in LICENSE_NAMES


def run(command: list[str], cwd: Path) -> str:
  environment = {
    **os.environ,
    "GOPROXY": "off",
    "GOSUMDB": "off",
    "GOFLAGS": "-buildvcs=false",
  }
  return subprocess.run(
    command,
    cwd=cwd,
    env=environment,
    check=True,
    text=True,
    stdout=subprocess.PIPE,
  ).stdout


def normalized_build_info(binary: Path, source_root: Path) -> str:
  output = run(["go", "version", "-m", str(binary)], source_root)
  lines = output.splitlines()
  if not lines:
    fail("go version -m returned no build metadata")
  _, separator, version = lines[0].partition(": ")
  if not separator:
    fail("go version -m first line is malformed")
  lines[0] = f"/cloudflared: {version}"
  return "\n".join(lines) + "\n"


def compiled_packages(source_root: Path) -> str:
  output = run(
    ["go", "list", "-mod=vendor", "-deps", "./cmd/cloudflared"],
    source_root,
  )
  return "\n".join(sorted(set(output.splitlines()))) + "\n"


def module_paths(build_info: str) -> set[str]:
  modules: set[str] = {"github.com/cloudflare/cloudflared"}
  lines = build_info.splitlines()
  index = 0
  while index < len(lines):
    fields = lines[index].split("\t")
    if len(fields) >= 4 and fields[1] == "dep":
      modules.add(fields[2])
      if index + 1 < len(lines):
        replacement = lines[index + 1].split("\t")
        if len(replacement) >= 4 and replacement[1] == "=>":
          modules.add(replacement[2])
          index += 1
    index += 1
  return modules


def read_inventory() -> list[dict[str, str]]:
  with INVENTORY.open(newline="", encoding="utf-8") as handle:
    reader = csv.DictReader(handle)
    if reader.fieldnames != ["package", "license_url", "spdx"]:
      fail("Cloudflared license inventory header changed")
    rows = list(reader)
  if not rows:
    fail("Cloudflared license inventory is empty")
  for row in rows:
    if not all(row.values()) or row["spdx"].lower() in {"unknown", "noassertion"}:
      fail(f"incomplete Cloudflared license row: {row}")
  return rows


def verify_inventory(build_info: str, source_root: Path) -> None:
  rows = read_inventory()
  packages = {row["package"] for row in rows}
  for module in sorted(module_paths(build_info)):
    if module not in packages and not any(package.startswith(f"{module}/") for package in packages):
      fail(f"compiled module is absent from the license inventory: {module}")

  pinned_fragment = f"/blob/{COMMIT}/"
  external_fragments = {
    "github.com/facebookgo/grace": "/blob/75cf19382434e82df4dd84953f566b8ad23d6e9e/",
    "github.com/chungthuang/quic-go": "/blob/a9fddf436fc41fcff5e5dd9ccee0fe0dcd71b59c/",
    "github.com/ipostelnik/cli/v2": "/blob/b6ea8234fe3daa46f5f1777d141b30eb091c2469/",
  }
  by_package = {row["package"]: row for row in rows}
  for row in rows:
    expected = external_fragments.get(row["package"], pinned_fragment)
    if expected not in row["license_url"]:
      fail(f"license URL is not pinned to its exact source: {row['package']}")

  required_conclusions = {
    "github.com/klauspost/compress": "BSD-3-Clause AND Apache-2.0 AND MIT",
    "gopkg.in/yaml.v2": "Apache-2.0 AND MIT",
    "gopkg.in/yaml.v3": "Apache-2.0 AND MIT",
    "github.com/facebookgo/grace": "MIT",
  }
  for package, expected in required_conclusions.items():
    actual = by_package.get(package, {}).get("spdx")
    if actual != expected:
      fail(f"incorrect SPDX conclusion for {package}: {actual!r}")

  source_license = source_root / "LICENSE"
  retained_license = LICENSE_ROOT / "LICENSE"
  if not source_license.is_file() or not retained_license.is_file():
    fail("Cloudflared top-level license is missing")
  if sha256(source_license) != sha256(retained_license):
    fail("retained Cloudflared top-level license differs from pinned source")

  vendor = source_root / "vendor"
  source_notices = {
    path.relative_to(vendor): path
    for path in vendor.rglob("*")
    if path.is_file() and is_license_file(path)
  }
  retained_notices = {
    path.relative_to(LICENSE_ROOT / "dependencies"): path
    for path in (LICENSE_ROOT / "dependencies").rglob("*")
    if path.is_file()
  }
  for relative, path in source_notices.items():
    retained = retained_notices.get(relative)
    if retained is None or sha256(path) != sha256(retained):
      fail(f"retained Cloudflared notice differs or is missing: {relative}")
  allowed_extra = {Path(path) for path, _ in EXTERNAL_LICENSES.values()}
  actual_extra = {
    Path("dependencies") / relative
    for relative in retained_notices.keys() - source_notices.keys()
  }
  if actual_extra != allowed_extra:
    fail(f"unexpected retained Cloudflared notice files: {sorted(map(str, actual_extra))}")
  for package, (relative, expected_hash) in EXTERNAL_LICENSES.items():
    path = LICENSE_ROOT / relative
    if not path.is_file() or sha256(path) != expected_hash:
      fail(f"external license differs or is missing: {package}")


def copy_notices(source_root: Path) -> None:
  dependencies = LICENSE_ROOT / "dependencies"
  shutil.rmtree(dependencies, ignore_errors=True)
  dependencies.mkdir(parents=True)
  shutil.copyfile(source_root / "LICENSE", LICENSE_ROOT / "LICENSE")
  vendor = source_root / "vendor"
  for path in vendor.rglob("*"):
    if path.is_file() and is_license_file(path):
      target = dependencies / path.relative_to(vendor)
      target.parent.mkdir(parents=True, exist_ok=True)
      shutil.copyfile(path, target)


def verify_source_hashes(source_root: Path) -> None:
  provenance = json.loads((ROOT / "source" / "provenance.json").read_text(encoding="utf-8"))
  cloudflared = provenance["buildInputs"]["cloudflared"]
  expected = {
    "goModSha256": source_root / "go.mod",
    "goSumSha256": source_root / "go.sum",
    "vendorModulesSha256": source_root / "vendor" / "modules.txt",
    "licenseSha256": source_root / "LICENSE",
  }
  if cloudflared.get("commit") != COMMIT:
    fail("Cloudflared provenance commit changed")
  for key, path in expected.items():
    if cloudflared.get(key) != sha256(path):
      fail(f"Cloudflared provenance hash differs: {key}")


def verify_binary(build_info: str, binary: Path) -> None:
  provenance = json.loads((ROOT / "source" / "provenance.json").read_text(encoding="utf-8"))
  cloudflared = provenance["buildInputs"]["cloudflared"]
  if cloudflared.get("binarySha256") != sha256(binary):
    fail("Cloudflared binary hash differs from provenance")
  required = (
    "/cloudflared: go1.26.5",
    "\tdep\tgoogle.golang.org/grpc\tv1.83.0\t",
    "\tdep\tgolang.org/x/net\tv0.56.0\t",
    "\tdep\tgolang.org/x/text\tv0.40.0\t",
  )
  for marker in required:
    if marker not in build_info:
      fail(f"Cloudflared build is missing required metadata: {marker.strip()}")
  if "google.golang.org/grpc\tv1.81.1" in build_info:
    fail("Cloudflared still embeds the vulnerable gRPC version")


def main() -> None:
  parser = argparse.ArgumentParser()
  parser.add_argument("--source-root", required=True, type=Path)
  parser.add_argument("--binary", required=True, type=Path)
  parser.add_argument("--write", action="store_true")
  args = parser.parse_args()
  source_root = args.source_root.resolve()
  binary = args.binary.resolve()
  if not source_root.is_dir() or not binary.is_file():
    fail("Cloudflared source root or binary is missing")

  build_info = normalized_build_info(binary, source_root)
  packages = compiled_packages(source_root)
  if args.write:
    BUILD_INFO.write_text(build_info, encoding="utf-8")
    PACKAGES.write_text(packages, encoding="utf-8")
    copy_notices(source_root)
    print("wrote Cloudflared build, package, and notice evidence")
    return

  if BUILD_INFO.read_text(encoding="utf-8") != build_info:
    fail("checked-in Cloudflared build metadata is stale")
  if PACKAGES.read_text(encoding="utf-8") != packages:
    fail("checked-in Cloudflared compiled package closure is stale")
  verify_source_hashes(source_root)
  verify_binary(build_info, binary)
  verify_inventory(build_info, source_root)
  print(f"verified Cloudflared source build: {len(packages.splitlines())} compiled packages")


if __name__ == "__main__":
  main()
