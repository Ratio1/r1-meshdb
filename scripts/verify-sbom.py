#!/usr/bin/env python3
# Copyright 2026 Ratio1
# Licensed under the Apache License, Version 2.0. See LICENSE.

"""Verify source and runtime SBOM completeness against release inputs."""

from __future__ import annotations

import argparse
from collections import defaultdict
import json
from pathlib import Path
from urllib.parse import quote, unquote
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
APPLICATION_NAME = "R1 Distributed SQL"
APPLICATION_PURL = "pkg:generic/r1-distributed-sql"
APPLICATION_SUPPLIER = "Organization: Ratio1"
APPLICATION_SOURCE = "https://github.com/Ratio1/r1-distributed-sql"
EXPECTED_LICENSE_FILE_COUNT = 11_948
EXPECTED_VENDOR_MODULE_COUNT = 211
RUNTIME_BINARY_PATHS = ("/cockroach/cockroach", "/usr/local/bin/cloudflared")


def fail(message: str) -> None:
  print(f"SBOM error: {message}", file=sys.stderr)
  raise SystemExit(1)


def normalized_purl(value: str) -> str:
  return value.split("?", 1)[0].lower()


def debian_purl_identity(value: str) -> tuple[str, str] | None:
  prefix = "pkg:deb/debian/"
  base = value.split("?", 1)[0]
  if not base.lower().startswith(prefix) or "@" not in base:
    return None
  name, version = base[len(prefix):].rsplit("@", 1)
  return unquote(name).lower(), unquote(version)


def module_purl(module: str, version: str | None = None) -> str:
  result = f"pkg:golang/{module}"
  if version:
    result += f"@{quote(version, safe='.-_~')}"
  return normalized_purl(result)


def expected_native_components() -> dict[str, dict]:
  provenance = json.loads((ROOT / "source/provenance.json").read_text(encoding="utf-8"))
  return {
    normalized_purl(f"pkg:generic/{item['name']}@{item['commit']}"): item
    for item in provenance["nativeDependencies"]
  }


def expected_vendor_modules() -> dict[str, tuple[str, str]]:
  modules: dict[str, tuple[str, str]] = {}
  versioned = re.compile(r"^# (\S+) (\S+)(?: => (\S+) (\S+))?$")
  replacement_only = re.compile(r"^# (\S+) => (\S+) (\S+)$")
  for line in (ROOT / "engine/vendor/modules.txt").read_text(encoding="utf-8").splitlines():
    match = versioned.fullmatch(line)
    if match:
      original_name, original_version, replacement_name, replacement_version = match.groups()
      name = replacement_name or original_name
      version = replacement_version or original_version
      modules[module_purl(name, version)] = (name, version)
      continue
    match = replacement_only.fullmatch(line)
    if match:
      _, name, version = match.groups()
      modules[module_purl(name, version)] = (name, version)
  if len(modules) != EXPECTED_VENDOR_MODULE_COUNT:
    fail(
      "vendored module metadata differs from the release contract: "
      f"expected {EXPECTED_VENDOR_MODULE_COUNT}, found {len(modules)}"
    )
  return modules


def expected_license_files() -> dict[str, dict]:
  document = json.loads((ROOT / "source/license-inventory.json").read_text(encoding="utf-8"))
  records = document.get("files")
  if not isinstance(records, list) or len(records) != EXPECTED_LICENSE_FILE_COUNT:
    fail(
      "source license inventory differs from the release contract: "
      f"expected {EXPECTED_LICENSE_FILE_COUNT}, found "
      f"{len(records) if isinstance(records, list) else 'invalid'}"
    )
  by_path = {record.get("path"): record for record in records if isinstance(record, dict)}
  if None in by_path or len(by_path) != len(records):
    fail("source license inventory paths are missing or duplicated")
  return by_path


def expected_runtime_packages() -> dict[str, str]:
  packages: dict[str, str] = {}
  for line in (ROOT / "source/runtime-packages.txt").read_text(encoding="utf-8").splitlines():
    if not line or "=" not in line:
      fail(f"invalid runtime package record: {line!r}")
    name, version = line.split("=", 1)
    if not name or not version or name in packages:
      fail(f"invalid or duplicate runtime package record: {line!r}")
    packages[name] = version
  return packages


def source_path(value: str) -> str:
  path = value.lstrip("/")
  for prefix in ("source/", "source-snapshot/"):
    if path.startswith(prefix):
      return path[len(prefix):]
  return path


def spdx_purls(package: dict) -> list[str]:
  return [
    normalized_purl(reference.get("referenceLocator", ""))
    for reference in package.get("externalRefs", [])
    if reference.get("referenceType") == "purl" and reference.get("referenceLocator")
  ]


def cdx_locations(component: dict) -> tuple[str, ...]:
  return tuple(sorted(
    property_["value"]
    for property_ in component.get("properties", [])
    if re.fullmatch(r"syft:location:\d+:path", property_.get("name", ""))
    and isinstance(property_.get("value"), str)
  ))


def reject_duplicate_occurrences(records: list[tuple[str, tuple[str, ...], str]]) -> None:
  """Reject duplicate evidence while allowing one component per Syft location."""
  seen: set[tuple[str, tuple[str, ...]]] = set()
  for purl, locations, identifier in records:
    key = (purl, locations)
    if key in seen:
      fail(f"duplicate component occurrence for {purl}: {identifier}")
    seen.add(key)


def sha256_checksums(items: list[dict], algorithm_key: str, value_key: str) -> list[str]:
  return [
    item.get(value_key, "").lower()
    for item in items
    if item.get(algorithm_key) in {"SHA256", "SHA-256"}
  ]


def cdx_license_values(record: dict) -> set[str]:
  values = set()
  for item in record.get("licenses", []):
    if item.get("expression"):
      values.add(item["expression"])
    elif item.get("license", {}).get("id"):
      values.add(item["license"]["id"])
    elif item.get("license", {}).get("name"):
      values.add(item["license"]["name"])
  return values


def verify_spdx(document: dict) -> dict:
  if document.get("spdxVersion") != "SPDX-2.3" or document.get("dataLicense") != "CC0-1.0":
    fail("SPDX document metadata differs from the release contract")
  packages = document.get("packages")
  files = document.get("files", [])
  relationships = document.get("relationships")
  if not isinstance(packages, list) or not isinstance(files, list) or not isinstance(relationships, list):
    fail("SPDX packages, files, or relationships are malformed")

  identifiers = [document.get("SPDXID")]
  identifiers.extend(item.get("SPDXID") for item in packages)
  identifiers.extend(item.get("SPDXID") for item in files)
  if None in identifiers or len(identifiers) != len(set(identifiers)):
    fail("SPDX identifiers are missing or duplicated")
  known = set(identifiers)
  outgoing: dict[str, set[str]] = defaultdict(set)
  for relationship in relationships:
    left = relationship.get("spdxElementId")
    right = relationship.get("relatedSpdxElement")
    if left not in known or right not in known:
      fail("SPDX relationship refers to an unknown element")
    if relationship.get("relationshipType") in {"CONTAINS", "DEPENDS_ON", "DESCRIBES"}:
      outgoing[left].add(right)

  by_purl: dict[str, list[dict]] = defaultdict(list)
  occurrence_records: list[tuple[str, tuple[str, ...], str]] = []
  for package in packages:
    locations = (package.get("sourceInfo", ""),) if package.get("sourceInfo") else ()
    for purl in spdx_purls(package):
      by_purl[purl].append(package)
      occurrence_records.append((purl, locations, package["SPDXID"]))
  reject_duplicate_occurrences(occurrence_records)

  applications = by_purl.get(APPLICATION_PURL, [])
  if len(applications) != 1:
    fail("SPDX application identity is missing or duplicated")
  application = applications[0]
  if (
    application.get("name") != APPLICATION_NAME
    or application.get("supplier") != APPLICATION_SUPPLIER
    or application.get("downloadLocation") != APPLICATION_SOURCE
    or application.get("licenseDeclared") != "Apache-2.0"
  ):
    fail("SPDX application identity differs from the release contract")
  if application["SPDXID"] not in outgoing[document["SPDXID"]]:
    fail("SPDX application identity is disconnected from the document")

  expected_native = expected_native_components()
  for component_purl, component in expected_native.items():
    matches = by_purl.get(component_purl, [])
    if len(matches) != 1:
      fail(f"SPDX native component is missing or duplicated: {component['name']}")
    package = matches[0]
    if package.get("versionInfo") != component["commit"]:
      fail(f"SPDX native revision differs: {component['name']}")
    if package.get("licenseDeclared") != component["license"]:
      fail(f"SPDX native license differs: {component['name']}")
    checksums = sha256_checksums(package.get("checksums", []), "algorithm", "checksumValue")
    if checksums != [component["treeSha256"]]:
      fail(f"SPDX native tree hash differs: {component['name']}")
    if package["SPDXID"] not in outgoing[application["SPDXID"]]:
      fail(f"SPDX native component is disconnected from the application: {component['name']}")

  return {
    "application_id": application["SPDXID"],
    "by_purl": by_purl,
    "files": files,
    "outgoing": outgoing,
  }


def verify_cyclonedx(document: dict) -> dict:
  if document.get("bomFormat") != "CycloneDX" or document.get("specVersion") != "1.7":
    fail("CycloneDX document metadata differs from the release contract")
  root_ref = document.get("metadata", {}).get("component", {}).get("bom-ref")
  components = document.get("components")
  dependencies = document.get("dependencies")
  if not root_ref or not isinstance(components, list) or not isinstance(dependencies, list):
    fail("CycloneDX components, metadata root, or dependencies are malformed")
  references = [component.get("bom-ref") for component in components]
  if None in references or len(references) != len(set(references)) or root_ref in references:
    fail("CycloneDX component references are missing, duplicated, or collide with the root")
  known = set(references) | {root_ref}
  dependency_refs = [item.get("ref") for item in dependencies]
  if None in dependency_refs or len(dependency_refs) != len(set(dependency_refs)):
    fail("CycloneDX dependency references are missing or duplicated")
  outgoing: dict[str, set[str]] = defaultdict(set)
  for dependency in dependencies:
    reference = dependency.get("ref")
    depends_on = dependency.get("dependsOn", [])
    if reference not in known or not isinstance(depends_on, list) or not set(depends_on) <= known:
      fail("CycloneDX dependency graph refers to an unknown component")
    outgoing[reference].update(depends_on)

  by_purl: dict[str, list[dict]] = defaultdict(list)
  occurrence_records: list[tuple[str, tuple[str, ...], str]] = []
  for component in components:
    if component.get("purl"):
      purl = normalized_purl(component["purl"])
      by_purl[purl].append(component)
      occurrence_records.append((purl, cdx_locations(component), component["bom-ref"]))
  reject_duplicate_occurrences(occurrence_records)

  applications = by_purl.get(APPLICATION_PURL, [])
  if len(applications) != 1:
    fail("CycloneDX application identity is missing or duplicated")
  application = applications[0]
  suppliers = application.get("supplier", {})
  licenses = cdx_license_values(application)
  source_references = {
    item.get("url") for item in application.get("externalReferences", [])
    if item.get("type") == "vcs"
  }
  if (
    application.get("type") != "application"
    or application.get("name") != APPLICATION_NAME
    or suppliers.get("name") != "Ratio1"
    or "Apache-2.0" not in licenses
    or APPLICATION_SOURCE not in source_references
  ):
    fail("CycloneDX application identity differs from the release contract")
  if application["bom-ref"] not in outgoing[root_ref]:
    fail("CycloneDX application identity is disconnected from the document root")

  expected_native = expected_native_components()
  for component_purl, component in expected_native.items():
    matches = by_purl.get(component_purl, [])
    if len(matches) != 1:
      fail(f"CycloneDX native component is missing or duplicated: {component['name']}")
    record = matches[0]
    if record.get("version") != component["commit"]:
      fail(f"CycloneDX native revision differs: {component['name']}")
    licenses = cdx_license_values(record)
    if licenses != {component["license"]}:
      fail(f"CycloneDX native license differs: {component['name']}")
    hashes = sha256_checksums(record.get("hashes", []), "alg", "content")
    if hashes != [component["treeSha256"]]:
      fail(f"CycloneDX native tree hash differs: {component['name']}")
    if record["bom-ref"] not in outgoing[application["bom-ref"]]:
      fail(f"CycloneDX native component is disconnected from the application: {component['name']}")

  return {
    "application_id": application["bom-ref"],
    "by_purl": by_purl,
    "components": components,
    "outgoing": outgoing,
  }


def verify_source_spdx(view: dict) -> None:
  expected_files = expected_license_files()
  by_path: dict[str, list[dict]] = defaultdict(list)
  for file_ in view["files"]:
    path = source_path(file_.get("fileName", ""))
    if path in expected_files:
      by_path[path].append(file_)
  if set(by_path) != set(expected_files):
    missing = sorted(set(expected_files) - set(by_path))
    fail(f"SPDX source license inventory is incomplete: {missing[:3]}")
  for path, expected in expected_files.items():
    records = by_path[path]
    if len(records) != 1:
      fail(f"SPDX source file is duplicated: {path}")
    record = records[0]
    hashes = sha256_checksums(record.get("checksums", []), "algorithm", "checksumValue")
    if hashes != [expected["sha256"]]:
      fail(f"SPDX source file hash differs: {path}")
    if record.get("licenseConcluded") != expected["spdx"]:
      fail(f"SPDX source file license differs: {path}")
    if set(record.get("licenseInfoInFiles", [])) != {expected["spdx"]}:
      fail(f"SPDX source file license evidence is absent: {path}")
    if record["SPDXID"] not in view["outgoing"][view["application_id"]]:
      fail(f"SPDX source file is disconnected from the application: {path}")


def cdx_properties(component: dict) -> dict[str, list[str]]:
  result: dict[str, list[str]] = defaultdict(list)
  for property_ in component.get("properties", []):
    if isinstance(property_.get("name"), str) and isinstance(property_.get("value"), str):
      result[property_["name"]].append(property_["value"])
  return result


def verify_source_cyclonedx(view: dict) -> None:
  expected_files = expected_license_files()
  by_path: dict[str, list[dict]] = defaultdict(list)
  for component in view["components"]:
    properties = cdx_properties(component)
    for path in properties.get("io.ratio1.source.path", []):
      by_path[path].append(component)
  if set(by_path) != set(expected_files):
    missing = sorted(set(expected_files) - set(by_path))
    extra = sorted(set(by_path) - set(expected_files))
    fail(f"CycloneDX source license inventory differs: missing={missing[:3]} extra={extra[:3]}")
  for path, expected in expected_files.items():
    records = by_path[path]
    if len(records) != 1:
      fail(f"CycloneDX source file is duplicated: {path}")
    record = records[0]
    if record.get("type") != "file":
      fail(f"CycloneDX source inventory component is not a file: {path}")
    hashes = sha256_checksums(record.get("hashes", []), "alg", "content")
    if hashes != [expected["sha256"]]:
      fail(f"CycloneDX source file hash differs: {path}")
    licenses = cdx_license_values(record)
    if licenses != {expected["spdx"]}:
      fail(f"CycloneDX source file license differs: {path}")
    properties = cdx_properties(record)
    if properties.get("io.ratio1.source.license-basis") != [expected["basis"]]:
      fail(f"CycloneDX source file license basis differs: {path}")
    if record["bom-ref"] not in view["outgoing"][view["application_id"]]:
      fail(f"CycloneDX source file is disconnected from the application: {path}")


def verify_source_modules(view: dict, format_name: str) -> None:
  expected = expected_vendor_modules()
  found = {
    purl: records
    for purl, records in view["by_purl"].items()
    if purl.startswith("pkg:golang/")
  }
  if set(found) != set(expected):
    missing = sorted(set(expected) - set(found))
    extra = sorted(set(found) - set(expected))
    fail(f"{format_name} vendored Go module set differs: missing={missing[:3]} extra={extra[:3]}")
  for purl, (name, version) in expected.items():
    records = found[purl]
    if len(records) != 1:
      fail(f"{format_name} vendored Go module is duplicated: {purl}")
    record = records[0]
    actual_version = record.get("versionInfo") if format_name == "SPDX" else record.get("version")
    if record.get("name") != name or actual_version != version:
      fail(f"{format_name} vendored Go module identity differs: {purl}")
    identifier = record.get("SPDXID") if format_name == "SPDX" else record.get("bom-ref")
    if identifier not in view["outgoing"][view["application_id"]]:
      fail(f"{format_name} vendored Go module is disconnected from the application: {purl}")


def buildinfo_purls(path: Path) -> set[str]:
  effective: list[tuple[str, str]] = []
  for line in path.read_text(encoding="utf-8").splitlines():
    fields = line.strip().split("\t")
    if not fields:
      continue
    if fields[0] == "dep" and len(fields) >= 3:
      effective.append((fields[1], fields[2]))
    elif fields[0] == "=>" and len(fields) >= 3 and effective:
      effective[-1] = (fields[1], fields[2])
  return {module_purl(module, version) for module, version in effective}


def verify_runtime_packages(view: dict, format_name: str) -> None:
  for name, version in expected_runtime_packages().items():
    matches = [
      record
      for purl, records in view["by_purl"].items()
      if debian_purl_identity(purl) == (name.lower(), version)
      for record in records
    ]
    if len(matches) != 1:
      fail(f"{format_name} runtime package is missing or duplicated: {name}={version}")
    record = matches[0]
    actual_version = record.get("versionInfo") if format_name == "SPDX" else record.get("version")
    if record.get("name") != name or actual_version != version:
      fail(f"{format_name} runtime package identity differs: {name}={version}")
    identifier = record.get("SPDXID") if format_name == "SPDX" else record.get("bom-ref")
    if identifier not in view["outgoing"][view["application_id"]]:
      fail(f"{format_name} runtime package is disconnected from the application: {name}={version}")


def verify_runtime_binaries_spdx(view: dict) -> None:
  for runtime_path in RUNTIME_BINARY_PATHS:
    matches = [file_ for file_ in view["files"] if "/" + file_.get("fileName", "").lstrip("/") == runtime_path]
    if len(matches) != 1:
      fail(f"SPDX runtime binary is missing or duplicated: {runtime_path}")
    record = matches[0]
    hashes = sha256_checksums(record.get("checksums", []), "algorithm", "checksumValue")
    if len(hashes) != 1 or not re.fullmatch(r"[0-9a-f]{64}", hashes[0]):
      fail(f"SPDX runtime binary lacks one SHA-256 checksum: {runtime_path}")
    if record["SPDXID"] not in view["outgoing"][view["application_id"]]:
      fail(f"SPDX runtime binary is disconnected from the application: {runtime_path}")


def verify_runtime_binaries_cyclonedx(view: dict) -> None:
  for runtime_path in RUNTIME_BINARY_PATHS:
    matches = [
      component for component in view["components"]
      if component.get("type") == "file"
      and "/" + component.get("name", "").lstrip("/") == runtime_path
    ]
    if len(matches) != 1:
      fail(f"CycloneDX runtime binary is missing or duplicated: {runtime_path}")
    record = matches[0]
    hashes = sha256_checksums(record.get("hashes", []), "alg", "content")
    if len(hashes) != 1 or not re.fullmatch(r"[0-9a-f]{64}", hashes[0]):
      fail(f"CycloneDX runtime binary lacks one SHA-256 checksum: {runtime_path}")
    if record["bom-ref"] not in view["outgoing"][view["application_id"]]:
      fail(f"CycloneDX runtime binary is disconnected from the application: {runtime_path}")


def main() -> None:
  parser = argparse.ArgumentParser()
  parser.add_argument("sbom", type=Path)
  parser.add_argument("--require-runtime", action="store_true")
  parser.add_argument("--go-buildinfo", type=Path, action="append", default=[])
  args = parser.parse_args()

  document = json.loads(args.sbom.read_text(encoding="utf-8"))
  if document.get("spdxVersion", "").startswith("SPDX-"):
    format_name = "SPDX"
    view = verify_spdx(document)
  elif document.get("bomFormat") == "CycloneDX":
    format_name = "CycloneDX"
    view = verify_cyclonedx(document)
  else:
    fail("unsupported SBOM format")

  if args.require_runtime:
    if len(args.go_buildinfo) != 2:
      fail("runtime verification requires engine and Cloudflared Go build information")
    expected_buildinfo = set().union(*(buildinfo_purls(path) for path in args.go_buildinfo))
    missing = sorted(expected_buildinfo - set(view["by_purl"]))
    if missing:
      fail(f"compiled Go modules are absent from the {format_name} SBOM: {missing[:3]}")
    verify_runtime_packages(view, format_name)
    if format_name == "SPDX":
      verify_runtime_binaries_spdx(view)
    else:
      verify_runtime_binaries_cyclonedx(view)
    print(
      f"verified {format_name} runtime SBOM: {len(expected_runtime_packages())} packages, "
      f"{len(expected_buildinfo)} compiled Go modules, {len(RUNTIME_BINARY_PATHS)} binaries"
    )
  else:
    verify_source_modules(view, format_name)
    if format_name == "SPDX":
      verify_source_spdx(view)
    else:
      verify_source_cyclonedx(view)
    print(
      f"verified {format_name} source SBOM: {EXPECTED_VENDOR_MODULE_COUNT} vendored Go modules, "
      f"{EXPECTED_LICENSE_FILE_COUNT} licensed files"
    )


if __name__ == "__main__":
  main()
