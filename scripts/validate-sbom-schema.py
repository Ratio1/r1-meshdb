#!/usr/bin/env python3
# Copyright 2026 Ratio1
# Licensed under the Apache License, Version 2.0. See LICENSE.

"""Validate release SBOMs with the vendored official JSON schemas."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from jsonschema import Draft7Validator, RefResolver


ROOT = Path(__file__).resolve().parents[1]


def schema_store() -> dict[str, dict]:
  store = {}
  paths = [ROOT / "schemas/spdx/spdx-2.3.schema.json"]
  paths.extend(sorted((ROOT / "schemas/cyclonedx").glob("*.json")))
  for path in paths:
    document = json.loads(path.read_text(encoding="utf-8"))
    store[path.resolve().as_uri()] = document
    for key in ("$id", "id"):
      identifier = document.get(key)
      if isinstance(identifier, str) and identifier:
        store[identifier] = document
  return store


def reject_remote_schema(uri: str):
  raise RuntimeError(f"SBOM schema attempted remote resolution: {uri}")


def validate(instance_path: Path) -> None:
  instance = json.loads(instance_path.read_text(encoding="utf-8"))
  if instance.get("spdxVersion") == "SPDX-2.3":
    schema_path = ROOT / "schemas/spdx/spdx-2.3.schema.json"
  elif instance.get("bomFormat") == "CycloneDX" and instance.get("specVersion") == "1.7":
    schema_path = ROOT / "schemas/cyclonedx/bom-1.7.schema.json"
  else:
    raise SystemExit(f"unsupported SBOM version: {instance_path}")
  schema = json.loads(schema_path.read_text(encoding="utf-8"))
  resolver = RefResolver.from_schema(
    schema,
    store=schema_store(),
    handlers={"http": reject_remote_schema, "https": reject_remote_schema},
  )
  errors = sorted(Draft7Validator(schema, resolver=resolver).iter_errors(instance), key=lambda item: list(item.path))
  if errors:
    first = errors[0]
    location = "/".join(str(part) for part in first.absolute_path) or "<document>"
    raise SystemExit(f"SBOM schema error in {instance_path} at {location}: {first.message}")
  print(f"schema-valid SBOM: {instance_path}")


def main() -> None:
  parser = argparse.ArgumentParser()
  parser.add_argument("sbom", type=Path, nargs="+")
  args = parser.parse_args()
  for path in args.sbom:
    validate(path.resolve())


if __name__ == "__main__":
  main()
