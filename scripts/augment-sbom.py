#!/usr/bin/env python3
# Copyright 2026 Ratio1
# Licensed under the Apache License, Version 2.0. See LICENSE.

"""Add release-owned application, native, and source-inventory SBOM records."""

from __future__ import annotations

import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import re
from urllib.parse import quote, unquote


ROOT = Path(__file__).resolve().parents[1]
PROVENANCE = ROOT / "source/provenance.json"
LICENSE_INVENTORY = ROOT / "source/license-inventory.json"
APPLICATION_NAME = "R1 MeshDB"
APPLICATION_VERSION = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", APPLICATION_VERSION):
  raise RuntimeError("VERSION must use canonical MAJOR.MINOR.PATCH")
APPLICATION_PURL = f"pkg:generic/r1-meshdb@{APPLICATION_VERSION}"
APPLICATION_SOURCE = "https://github.com/Ratio1/r1-meshdb"
APPLICATION_LICENSE = "Apache-2.0"
AGGREGATE_LICENSE_REF = "LicenseRef-Aggregate-License-Text"
RUNTIME_BINARY_PATHS = ("/cockroach/cockroach", "/usr/local/bin/cloudflared")
RUNTIME_SOURCE_MAPPING = ROOT / "source/runtime-package-sources.tsv"


def native_components() -> list[dict]:
  document = json.loads(PROVENANCE.read_text(encoding="utf-8"))
  return document["nativeDependencies"]


def license_inventory() -> list[dict]:
  document = json.loads(LICENSE_INVENTORY.read_text(encoding="utf-8"))
  return document["files"]


def runtime_source_mappings() -> dict[str, tuple[str, str, str]]:
  lines = RUNTIME_SOURCE_MAPPING.read_text(encoding="utf-8").splitlines()
  if not lines or lines[0] != "binary-package\tbinary-version\tsource-package\tsource-version":
    raise SystemExit("Debian runtime source mapping header is invalid")
  mappings = {}
  for line in lines[1:]:
    fields = line.split("\t")
    if len(fields) != 4 or not all(fields) or fields[0] in mappings:
      raise SystemExit(f"Debian runtime source mapping is invalid: {line!r}")
    mappings[fields[0]] = (fields[1], fields[2], fields[3])
  return mappings


def debian_purl_identity(value: str) -> tuple[str, str] | None:
  prefix = "pkg:deb/debian/"
  base = value.split("?", 1)[0]
  if not base.lower().startswith(prefix) or "@" not in base:
    return None
  name, version = base[len(prefix):].rsplit("@", 1)
  return unquote(name).lower(), unquote(version)


def debian_source_purl(name: str, version: str) -> str:
  return f"pkg:generic/debian-source/{quote(name, safe='.-_~')}@{quote(version, safe='.-_~')}"


def debian_source_url(name: str, version: str) -> str:
  return f"https://snapshot.debian.org/package/{quote(name, safe='')}/{quote(version, safe='')}/"


def source_text(record: dict) -> str:
  path = ROOT / record["path"]
  content = path.read_bytes()
  if hashlib.sha256(content).hexdigest() != record["sha256"]:
    raise SystemExit(f"license inventory checksum differs from source: {record['path']}")
  try:
    return content.decode("utf-8")
  except UnicodeDecodeError as error:
    raise SystemExit(f"custom license text is not UTF-8: {record['path']}") from error


def custom_license_id(record: dict) -> str:
  base = record["spdx"].removeprefix("LicenseRef-")
  base = re.sub(r"-(?:SHA256-)?[0-9a-f]{12,64}$", "", base)
  return f"LicenseRef-{base}-SHA256-{record['sha256']}"


def custom_license_text(record: dict) -> str:
  content = source_text(record)
  if "notice in source header" not in record.get("basis", "").lower():
    return content
  lines = content.splitlines(keepends=True)
  if lines and lines[0].lstrip().startswith("//"):
    header_lines = []
    for line in lines:
      if not line.lstrip().startswith("//"):
        break
      header_lines.append(line)
    header = "".join(header_lines)
  elif lines and lines[0].lstrip().startswith("/*"):
    end = next((index for index, line in enumerate(lines) if "*/" in line), -1)
    header = "".join(lines[:end + 1]) if end >= 0 else ""
  else:
    header = ""
  if "public domain" not in header.lower():
    raise SystemExit(f"custom source-header license notice is not extractable: {record['path']}")
  return header


def source_license(record: dict) -> tuple[str, str | None, str | None]:
  """Return the SBOM conclusion, comment, and exact custom text for a file."""
  expression = record["spdx"]
  if expression in {AGGREGATE_LICENSE_REF, "NOASSERTION"}:
    return (
      "NOASSERTION",
      "Aggregate license/notice document; no single license conclusion is asserted. "
      f"Inventory basis: {record['basis']}",
      None,
    )
  if expression.startswith("LicenseRef-"):
    return custom_license_id(record), None, custom_license_text(record)
  return expression, None, None


def purl(component: dict) -> str:
  return f"pkg:generic/{component['name']}@{component['commit']}"


def normalized_purl(value: str) -> str:
  return value.split("?", 1)[0].lower()


def is_application_purl(value: str) -> bool:
  normalized = normalized_purl(value)
  return normalized == "pkg:generic/r1-meshdb" or normalized.startswith(
    "pkg:generic/r1-meshdb@"
  )


def source_path(value: str) -> str:
  path = value.lstrip("/")
  for prefix in ("source/", "source-snapshot/"):
    if path.startswith(prefix):
      return path[len(prefix):]
  return path


def source_file_id(path: str) -> str:
  return hashlib.sha256(path.encode("utf-8")).hexdigest()[:24]


def add_spdx_relationship(relationships: list[dict], left: str, kind: str, right: str) -> None:
  relationship = {
    "spdxElementId": left,
    "relationshipType": kind,
    "relatedSpdxElement": right,
  }
  if relationship not in relationships:
    relationships.append(relationship)


def is_spdx_source(document: dict) -> bool:
  names = [document.get("name", "")]
  names.extend(package.get("name", "") for package in document.get("packages", []))
  return any(name.rstrip("/").rsplit("/", 1)[-1] in {"source", "source-snapshot"} for name in names)


def augment_spdx(document: dict, components: list[dict]) -> None:
  packages = document.setdefault("packages", [])
  files = document.setdefault("files", [])
  relationships = document.setdefault("relationships", [])
  document_id = document.get("SPDXID", "SPDXRef-DOCUMENT")
  license_infos = document.setdefault("hasExtractedLicensingInfos", [])
  if not isinstance(license_infos, list):
    raise SystemExit("SPDX extracted licensing information is malformed")
  license_infos_by_id: dict[str, list[dict]] = defaultdict(list)
  for info in license_infos:
    license_infos_by_id[info.get("licenseId", "")].append(info)

  by_purl: dict[str, list[dict]] = defaultdict(list)
  for package in packages:
    for reference in package.get("externalRefs", []):
      if reference.get("referenceType") == "purl" and reference.get("referenceLocator"):
        by_purl[normalized_purl(reference["referenceLocator"])].append(package)

  applications = by_purl.get(APPLICATION_PURL, [])
  conflicting_applications = [
    package for package in packages
    if package not in applications and (
      package.get("name") == APPLICATION_NAME
      or any(
        is_application_purl(reference.get("referenceLocator", ""))
        for reference in package.get("externalRefs", [])
        if reference.get("referenceType") == "purl"
      )
    )
  ]
  if conflicting_applications:
    raise SystemExit("SPDX application identity conflicts with the versioned R1 MeshDB PURL")
  if len(applications) > 1:
    raise SystemExit("SPDX application identity is duplicated")
  if applications:
    application = applications[0]
  else:
    application = {
      "SPDXID": "SPDXRef-Package-r1-meshdb",
      "name": APPLICATION_NAME,
      "versionInfo": APPLICATION_VERSION,
      "supplier": "Organization: Ratio1",
      "downloadLocation": APPLICATION_SOURCE,
      "filesAnalyzed": False,
      "licenseConcluded": APPLICATION_LICENSE,
      "licenseDeclared": APPLICATION_LICENSE,
      "copyrightText": "Copyright 2026 Ratio1",
      "externalRefs": [{
        "referenceCategory": "PACKAGE-MANAGER",
        "referenceType": "purl",
        "referenceLocator": APPLICATION_PURL,
      }],
      "summary": "R1 MeshDB decentralized distributed database application",
    }
    packages.append(application)
    by_purl[APPLICATION_PURL].append(application)
  application["licenseConcluded"] = APPLICATION_LICENSE
  application["licenseDeclared"] = APPLICATION_LICENSE
  application["name"] = APPLICATION_NAME
  application["versionInfo"] = APPLICATION_VERSION
  application_id = application["SPDXID"]
  add_spdx_relationship(relationships, document_id, "DESCRIBES", application_id)

  mappings = runtime_source_mappings()
  binary_packages: dict[str, dict] = {}
  for package in packages:
    for reference in package.get("externalRefs", []):
      if reference.get("referenceType") != "purl":
        continue
      identity = debian_purl_identity(reference.get("referenceLocator", ""))
      if identity and identity[0] in mappings and identity[1] == mappings[identity[0]][0]:
        if identity[0] in binary_packages:
          raise SystemExit(f"SPDX Debian runtime package is duplicated: {identity[0]}")
        binary_packages[identity[0]] = package
  if binary_packages:
    if set(binary_packages) != set(mappings):
      raise SystemExit("SPDX Debian runtime package set is incomplete")
    source_packages: dict[tuple[str, str], dict] = {}
    for binary_name, (_, source_name, source_version) in mappings.items():
      source_key = (source_name, source_version)
      source_purl = debian_source_purl(*source_key)
      if source_key not in source_packages:
        matches = by_purl.get(normalized_purl(source_purl), [])
        if len(matches) > 1:
          raise SystemExit(f"SPDX Debian source package is duplicated: {source_name}")
        if matches:
          source_package = matches[0]
        else:
          source_package = {
            "SPDXID": f"SPDXRef-Package-debian-source-{source_file_id(source_purl)}",
            "name": source_name,
            "versionInfo": source_version,
            "supplier": "Organization: Debian",
            "downloadLocation": debian_source_url(source_name, source_version),
            "filesAnalyzed": False,
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "NOASSERTION",
            "copyrightText": "NOASSERTION",
            "externalRefs": [{
              "referenceCategory": "PACKAGE-MANAGER",
              "referenceType": "purl",
              "referenceLocator": source_purl,
            }],
            "summary": "Exact Debian corresponding-source package accompanying the R1 MeshDB runtime image",
          }
          packages.append(source_package)
          by_purl[normalized_purl(source_purl)].append(source_package)
        source_packages[source_key] = source_package
        add_spdx_relationship(relationships, application_id, "DEPENDS_ON", source_package["SPDXID"])
      add_spdx_relationship(
        relationships,
        binary_packages[binary_name]["SPDXID"],
        "GENERATED_FROM",
        source_packages[source_key]["SPDXID"],
      )

  for component in components:
    component_purl = purl(component)
    matches = by_purl.get(normalized_purl(component_purl), [])
    if len(matches) > 1:
      raise SystemExit(f"SPDX native component is duplicated: {component['name']}")
    if matches:
      package = matches[0]
    else:
      spdx_id = f"SPDXRef-Package-r1-native-{re.sub(r'[^A-Za-z0-9.-]', '-', component['name'])}"
      package = {
        "SPDXID": spdx_id,
        "name": component["name"],
        "versionInfo": component["commit"],
        "supplier": "Organization: upstream project maintainers",
        "downloadLocation": f"{component['sourceUrl']}#{component['commit']}",
        "filesAnalyzed": False,
        "licenseConcluded": component["license"],
        "licenseDeclared": component["license"],
        "copyrightText": "NOASSERTION",
        "checksums": [{
          "algorithm": "SHA256",
          "checksumValue": component["treeSha256"],
        }],
        "externalRefs": [{
          "referenceCategory": "PACKAGE-MANAGER",
          "referenceType": "purl",
          "referenceLocator": component_purl,
        }],
        "summary": component["role"],
      }
      packages.append(package)
      by_purl[normalized_purl(component_purl)].append(package)
    add_spdx_relationship(relationships, application_id, "DEPENDS_ON", package["SPDXID"])

  if is_spdx_source(document):
    expected = {record["path"]: record for record in license_inventory()}
    by_path: dict[str, list[dict]] = defaultdict(list)
    for file_ in files:
      path = source_path(file_.get("fileName", ""))
      if path in expected:
        by_path[path].append(file_)
    for path, record in expected.items():
      concluded_license, license_comment, extracted_text = source_license(record)
      matches = by_path.get(path, [])
      if len(matches) > 1:
        raise SystemExit(f"SPDX source file is duplicated: {path}")
      if matches:
        file_ = matches[0]
        existing_hashes = {
          item.get("checksumValue", "").lower()
          for item in file_.get("checksums", [])
          if item.get("algorithm") == "SHA256"
        }
        if existing_hashes and existing_hashes != {record["sha256"]}:
          raise SystemExit(f"SPDX source file checksum conflicts with inventory: {path}")
        existing_license = file_.get("licenseConcluded")
        if existing_license not in {
          None, "NOASSERTION", record["spdx"], concluded_license,
        }:
          raise SystemExit(f"SPDX source file license conflicts with inventory: {path}")
      else:
        file_ = {
          "SPDXID": f"SPDXRef-File-r1-source-{source_file_id(path)}",
          "fileName": path,
          "copyrightText": "NOASSERTION",
        }
        files.append(file_)
      file_["checksums"] = [
        item for item in file_.get("checksums", []) if item.get("algorithm") != "SHA256"
      ] + [{"algorithm": "SHA256", "checksumValue": record["sha256"]}]
      file_["licenseConcluded"] = concluded_license
      file_["licenseInfoInFiles"] = [concluded_license]
      if license_comment:
        file_["licenseComments"] = license_comment
      else:
        file_.pop("licenseComments", None)
      if extracted_text is not None:
        license_id = concluded_license
        expected_info = {
          "licenseId": license_id,
          "name": f"Exact license or notice text SHA-256 {record['sha256']}",
          "extractedText": extracted_text,
        }
        existing_infos = license_infos_by_id.get(license_id, [])
        if len(existing_infos) > 1 or (
          existing_infos and existing_infos[0] != expected_info
        ):
          raise SystemExit(f"SPDX custom license definition conflicts: {license_id}")
        if not existing_infos:
          license_infos.append(expected_info)
          license_infos_by_id[license_id].append(expected_info)
      add_spdx_relationship(relationships, application_id, "CONTAINS", file_["SPDXID"])

  runtime_files = {
    "/" + file_.get("fileName", "").lstrip("/"): file_
    for file_ in files
    if "/" + file_.get("fileName", "").lstrip("/") in RUNTIME_BINARY_PATHS
  }
  for runtime_path in RUNTIME_BINARY_PATHS:
    if runtime_path in runtime_files:
      add_spdx_relationship(
        relationships, application_id, "CONTAINS", runtime_files[runtime_path]["SPDXID"]
      )

  # Existing Syft package records are dependencies of the release application.
  for package in packages:
    if package is application:
      continue
    package_purls = {
      normalized_purl(reference.get("referenceLocator", ""))
      for reference in package.get("externalRefs", [])
      if reference.get("referenceType") == "purl"
    }
    if package_purls:
      add_spdx_relationship(relationships, application_id, "DEPENDS_ON", package["SPDXID"])

  packages.sort(key=lambda package: (package.get("name", ""), package.get("SPDXID", "")))
  files.sort(key=lambda file_: (file_.get("fileName", ""), file_.get("SPDXID", "")))
  relationships.sort(key=lambda item: (
    item.get("spdxElementId", ""), item.get("relationshipType", ""),
    item.get("relatedSpdxElement", ""),
  ))
  license_infos.sort(key=lambda item: item.get("licenseId", ""))


def add_cdx_property(component: dict, name: str, value: str) -> None:
  properties = component.setdefault("properties", [])
  matches = [item for item in properties if item.get("name") == name]
  if len(matches) > 1 or (matches and matches[0].get("value") != value):
    raise SystemExit(f"CycloneDX property conflicts with release inventory: {name}")
  if not matches:
    properties.append({"name": name, "value": value})
  properties.sort(key=lambda item: (item.get("name", ""), item.get("value", "")))


def cdx_license_choice(spdx: str, extracted_text: str | None = None) -> dict:
  if re.search(r"\s(?:AND|OR|WITH)\s", spdx):
    return {"expression": spdx}
  if spdx.startswith("LicenseRef-"):
    license_record = {"name": spdx}
    if extracted_text is not None:
      license_record["text"] = {
        "contentType": "text/plain; charset=utf-8",
        "content": extracted_text,
      }
    return {"license": license_record}
  return {"license": {"id": spdx}}


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


def is_cdx_source(document: dict) -> bool:
  root = document.get("metadata", {}).get("component", {})
  name = root.get("name", "")
  return name.rstrip("/").rsplit("/", 1)[-1] in {"source", "source-snapshot"}


def augment_cyclonedx(document: dict, components: list[dict]) -> None:
  output_components = document.setdefault("components", [])
  dependencies = document.setdefault("dependencies", [])
  existing_refs = [component.get("bom-ref") for component in output_components]
  if None in existing_refs or len(existing_refs) != len(set(existing_refs)):
    raise SystemExit("CycloneDX component references are missing or duplicated")
  dependency_refs = [dependency.get("ref") for dependency in dependencies]
  if None in dependency_refs or len(dependency_refs) != len(set(dependency_refs)):
    raise SystemExit("CycloneDX dependency references are missing or duplicated")
  dependencies_by_ref = {dependency["ref"]: dependency for dependency in dependencies}
  root_ref = document.get("metadata", {}).get("component", {}).get("bom-ref")
  if not root_ref:
    raise SystemExit("CycloneDX metadata component lacks a bom-ref")
  root_dependency = dependencies_by_ref.setdefault(root_ref, {"ref": root_ref, "dependsOn": []})

  by_purl: dict[str, list[dict]] = defaultdict(list)
  for component in output_components:
    if component.get("purl"):
      by_purl[normalized_purl(component["purl"])].append(component)
  applications = by_purl.get(APPLICATION_PURL, [])
  conflicting_applications = [
    component for component in output_components
    if component not in applications and (
      component.get("name") == APPLICATION_NAME
      or is_application_purl(component.get("purl", ""))
    )
  ]
  if conflicting_applications:
    raise SystemExit("CycloneDX application identity conflicts with the versioned R1 MeshDB PURL")
  if len(applications) > 1:
    raise SystemExit("CycloneDX application identity is duplicated")
  if applications:
    application = applications[0]
  else:
    application = {
      "type": "application",
      "bom-ref": APPLICATION_PURL,
      "group": "Ratio1",
      "name": APPLICATION_NAME,
      "version": APPLICATION_VERSION,
      "purl": APPLICATION_PURL,
      "supplier": {"name": "Ratio1"},
      "licenses": [{"license": {"id": APPLICATION_LICENSE}}],
      "externalReferences": [{"type": "vcs", "url": APPLICATION_SOURCE}],
    }
    output_components.append(application)
    by_purl[APPLICATION_PURL].append(application)
  application["licenses"] = [{"license": {"id": APPLICATION_LICENSE}}]
  application["name"] = APPLICATION_NAME
  application["version"] = APPLICATION_VERSION
  application_ref = application["bom-ref"]
  application_dependency = dependencies_by_ref.setdefault(
    application_ref, {"ref": application_ref, "dependsOn": []}
  )
  if application_ref not in root_dependency["dependsOn"]:
    root_dependency["dependsOn"].append(application_ref)

  mappings = runtime_source_mappings()
  binary_components: dict[str, dict] = {}
  for component in output_components:
    identity = debian_purl_identity(component.get("purl", ""))
    if identity and identity[0] in mappings and identity[1] == mappings[identity[0]][0]:
      if identity[0] in binary_components:
        raise SystemExit(f"CycloneDX Debian runtime package is duplicated: {identity[0]}")
      binary_components[identity[0]] = component
  if binary_components:
    if set(binary_components) != set(mappings):
      raise SystemExit("CycloneDX Debian runtime package set is incomplete")
    source_components: dict[tuple[str, str], dict] = {}
    for binary_name, (_, source_name, source_version) in mappings.items():
      source_key = (source_name, source_version)
      source_purl = debian_source_purl(*source_key)
      if source_key not in source_components:
        matches = by_purl.get(normalized_purl(source_purl), [])
        if len(matches) > 1:
          raise SystemExit(f"CycloneDX Debian source package is duplicated: {source_name}")
        if matches:
          source_component = matches[0]
        else:
          source_component = {
            "type": "library",
            "bom-ref": source_purl,
            "group": "Debian Source",
            "name": source_name,
            "version": source_version,
            "purl": source_purl,
            "externalReferences": [{
              "type": "distribution",
              "url": debian_source_url(source_name, source_version),
            }],
            "properties": [{
              "name": "io.ratio1.debian.corresponding-source",
              "value": "included at /usr/share/src/r1-meshdb/debian",
            }],
          }
          output_components.append(source_component)
          by_purl[normalized_purl(source_purl)].append(source_component)
        source_components[source_key] = source_component
        dependencies_by_ref.setdefault(
          source_component["bom-ref"], {"ref": source_component["bom-ref"], "dependsOn": []}
        )
        if source_component["bom-ref"] not in application_dependency["dependsOn"]:
          application_dependency["dependsOn"].append(source_component["bom-ref"])
      binary_component = binary_components[binary_name]
      add_cdx_property(binary_component, "io.ratio1.debian.source-purl", source_purl)
      binary_dependency = dependencies_by_ref.setdefault(
        binary_component["bom-ref"], {"ref": binary_component["bom-ref"], "dependsOn": []}
      )
      if source_components[source_key]["bom-ref"] not in binary_dependency["dependsOn"]:
        binary_dependency["dependsOn"].append(source_components[source_key]["bom-ref"])

  for component in components:
    component_purl = purl(component)
    matches = by_purl.get(normalized_purl(component_purl), [])
    if len(matches) > 1:
      raise SystemExit(f"CycloneDX native component is duplicated: {component['name']}")
    if matches:
      record = matches[0]
    else:
      record = {
        "type": "library",
        "bom-ref": component_purl,
        "name": component["name"],
        "version": component["commit"],
        "purl": component_purl,
        "licenses": [{"license": {"id": component["license"]}}],
        "hashes": [{"alg": "SHA-256", "content": component["treeSha256"]}],
        "externalReferences": [{
          "type": "vcs",
          "url": f"{component['sourceUrl']}#{component['commit']}",
        }],
        "properties": [
          {"name": "io.ratio1.native.role", "value": component["role"]},
          {"name": "io.ratio1.native.source-tree-sha256", "value": component["treeSha256"]},
        ],
      }
      output_components.append(record)
      by_purl[normalized_purl(component_purl)].append(record)
    dependencies_by_ref.setdefault(record["bom-ref"], {"ref": record["bom-ref"], "dependsOn": []})
    if record["bom-ref"] not in application_dependency["dependsOn"]:
      application_dependency["dependsOn"].append(record["bom-ref"])

  if is_cdx_source(document):
    expected = {record["path"]: record for record in license_inventory()}
    by_path: dict[str, list[dict]] = defaultdict(list)
    for component in output_components:
      explicit_paths = [
        item.get("value") for item in component.get("properties", [])
        if item.get("name") == "io.ratio1.source.path"
      ]
      if explicit_paths:
        for path in explicit_paths:
          by_path[path].append(component)
      else:
        path = source_path(component.get("name", ""))
        if component.get("type") == "file" and path in expected:
          by_path[path].append(component)
    for path, inventory_record in expected.items():
      concluded_license, license_comment, extracted_text = source_license(inventory_record)
      matches = by_path.get(path, [])
      if len(matches) > 1:
        raise SystemExit(f"CycloneDX source file is duplicated: {path}")
      if matches:
        record = matches[0]
        existing_hashes = {
          item.get("content", "").lower()
          for item in record.get("hashes", []) if item.get("alg") == "SHA-256"
        }
        if existing_hashes and existing_hashes != {inventory_record["sha256"]}:
          raise SystemExit(f"CycloneDX source file checksum conflicts with inventory: {path}")
        existing_licenses = cdx_license_values(record)
        allowed_existing_licenses = {
          inventory_record["spdx"], concluded_license,
        }
        if existing_licenses and not existing_licenses <= allowed_existing_licenses:
          raise SystemExit(f"CycloneDX source file license conflicts with inventory: {path}")
      else:
        record = {
          "type": "file",
          "bom-ref": f"urn:ratio1:source-file:{source_file_id(path)}",
          "name": f"/source/{path}",
        }
        output_components.append(record)
      record["hashes"] = [
        item for item in record.get("hashes", []) if item.get("alg") != "SHA-256"
      ] + [{"alg": "SHA-256", "content": inventory_record["sha256"]}]
      if concluded_license == "NOASSERTION":
        record.pop("licenses", None)
      else:
        record["licenses"] = [cdx_license_choice(concluded_license, extracted_text)]
      add_cdx_property(record, "io.ratio1.source.path", path)
      add_cdx_property(record, "io.ratio1.source.license-basis", inventory_record["basis"])
      if license_comment:
        add_cdx_property(record, "io.ratio1.source.license-comment", license_comment)
      dependencies_by_ref.setdefault(record["bom-ref"], {"ref": record["bom-ref"], "dependsOn": []})
      if record["bom-ref"] not in application_dependency["dependsOn"]:
        application_dependency["dependsOn"].append(record["bom-ref"])

  for component in output_components:
    if component is application:
      continue
    if component.get("purl"):
      if component["bom-ref"] not in application_dependency["dependsOn"]:
        application_dependency["dependsOn"].append(component["bom-ref"])
    if (
      component.get("type") == "file"
      and "/" + component.get("name", "").lstrip("/") in RUNTIME_BINARY_PATHS
      and component["bom-ref"] not in application_dependency["dependsOn"]
    ):
      application_dependency["dependsOn"].append(component["bom-ref"])

  output_components.sort(key=lambda component: (component.get("name", ""), component.get("bom-ref", "")))
  for dependency in dependencies_by_ref.values():
    dependency["dependsOn"] = sorted(set(dependency.get("dependsOn", [])))
  dependencies[:] = sorted(dependencies_by_ref.values(), key=lambda dependency: dependency.get("ref", ""))


def main() -> None:
  parser = argparse.ArgumentParser()
  parser.add_argument("sbom", type=Path)
  args = parser.parse_args()

  document = json.loads(args.sbom.read_text(encoding="utf-8"))
  components = native_components()
  if document.get("spdxVersion", "").startswith("SPDX-"):
    augment_spdx(document, components)
  elif document.get("bomFormat") == "CycloneDX":
    augment_cyclonedx(document, components)
  else:
    raise SystemExit("unsupported SBOM format")
  args.sbom.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
  main()
