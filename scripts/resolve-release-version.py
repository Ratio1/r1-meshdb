#!/usr/bin/env python3
"""Resolve an immutable R1 MeshDB release identifier from VERSION."""

# Copyright 2026 Ratio1
# Licensed under the Apache License, Version 2.0. See LICENSE.

from __future__ import annotations

import argparse
from pathlib import Path
import re


VERSION_PATTERN = re.compile(
  r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"
)


def parse_version(value: str, label: str = "version") -> tuple[int, int, int]:
  match = VERSION_PATTERN.fullmatch(value)
  if match is None:
    raise ValueError(f"{label} must use canonical MAJOR.MINOR.PATCH: {value}")
  return tuple(int(component) for component in match.groups())


def resolve_release_version(
  version: str,
  *,
  previous_version: str | None = None,
  existing_tags: tuple[str, ...] = (),
  allow_current_tag: bool = False,
) -> dict[str, str]:
  current = parse_version(version, "VERSION")
  release_tag = f"v{version}"

  if previous_version is not None:
    previous = parse_version(previous_version, "previous VERSION")
    if current <= previous:
      raise ValueError("VERSION must increase on a release-triggering push")

  for tag in existing_tags:
    match = VERSION_PATTERN.fullmatch(tag.removeprefix("v")) if tag.startswith("v") else None
    if match is None:
      continue
    tagged = tuple(int(component) for component in match.groups())
    if tagged > current or (tagged == current and not allow_current_tag):
      raise ValueError(f"VERSION does not identify a new release: existing tag {tag}")

  return {"version": version, "release_tag": release_tag}


def read_version(path: Path, label: str) -> str:
  if not path.is_file():
    raise ValueError(f"{label} file does not exist: {path}")
  value = path.read_text(encoding="utf-8")
  if not value.endswith("\n") or value.count("\n") != 1:
    raise ValueError(f"{label} file must contain one newline-terminated version")
  return value.rstrip("\n")


def main() -> None:
  parser = argparse.ArgumentParser()
  parser.add_argument("--version-file", type=Path, default=Path("VERSION"))
  parser.add_argument("--previous-version-file", type=Path)
  parser.add_argument("--existing-tag", action="append", default=[])
  parser.add_argument("--allow-current-tag", action="store_true")
  parser.add_argument("--github-output", type=Path)
  args = parser.parse_args()

  try:
    version = read_version(args.version_file, "VERSION")
    previous = (
      read_version(args.previous_version_file, "previous VERSION")
      if args.previous_version_file is not None
      else None
    )
    resolved = resolve_release_version(
      version,
      previous_version=previous,
      existing_tags=tuple(args.existing_tag),
      allow_current_tag=args.allow_current_tag,
    )
  except ValueError as error:
    parser.error(str(error))

  lines = "".join(f"{key}={value}\n" for key, value in resolved.items())
  if args.github_output is None:
    print(lines, end="")
  else:
    with args.github_output.open("a", encoding="utf-8") as output:
      output.write(lines)


if __name__ == "__main__":
  main()
