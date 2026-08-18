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


ROOT = Path(__file__).resolve().parents[1]
PROVENANCE = ROOT / "source/provenance.json"
LICENSE_INVENTORY = ROOT / "source/license-inventory.json"
APPLICATION_NAME = "R1 Distributed SQL"
APPLICATION_PURL = "pkg:generic/r1-distributed-sql"
APPLICATION_SOURCE = "https://github.com/Ratio1/r1-distributed-sql"
DISTRIBUTION_THIRD_PARTY_LICENSE_ID = "LicenseRef-R1-Distributed-SQL-Third-Party"
DISTRIBUTION_LICENSE_EXPRESSION = (
  f"Apache-2.0 AND {DISTRIBUTION_THIRD_PARTY_LICENSE_ID}"
)
DISTRIBUTION_THIRD_PARTY_LICENSE_INFO = {
  "licenseId": DISTRIBUTION_THIRD_PARTY_LICENSE_ID,
  "name": "R1 Distributed SQL third-party license set",
  "extractedText": (
    "This reference identifies the third-party licenses that apply to software "
    "included in the R1 Distributed SQL source and image. It does not replace "
    "or modify those licenses. Exact component-level SPDX conclusions and full "
    "license texts are recorded in this SBOM, THIRD_PARTY_NOTICES.md, the source "
    "license inventory, and the license files shipped with the distribution."
  ),
  "seeAlsos": [
    "https://github.com/Ratio1/r1-distributed-sql/blob/main/THIRD_PARTY_NOTICES.md",
  ],
}
RUNTIME_BINARY_PATHS = ("/cockroach/cockroach", "/usr/local/bin/cloudflared")


def native_components() -> list[dict]:
  document = json.loads(PROVENANCE.read_text(encoding="utf-8"))
  return document["nativeDependencies"]


def license_inventory() -> list[dict]:
  document = json.loads(LICENSE_INVENTORY.read_text(encoding="utf-8"))
  return document["files"]


def purl(component: dict) -> str:
  return f"pkg:generic/{component['name']}@{component['commit']}"


def normalized_purl(value: str) -> str:
  return value.split("?", 1)[0].lower()


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
  matches = [
    item for item in license_infos
    if item.get("licenseId") == DISTRIBUTION_THIRD_PARTY_LICENSE_ID
  ]
  if len(matches) > 1 or (matches and matches[0] != DISTRIBUTION_THIRD_PARTY_LICENSE_INFO):
    raise SystemExit("SPDX distribution third-party license reference conflicts")
  if not matches:
    license_infos.append(dict(DISTRIBUTION_THIRD_PARTY_LICENSE_INFO))
  license_infos.sort(key=lambda item: item.get("licenseId", ""))

  by_purl: dict[str, list[dict]] = defaultdict(list)
  for package in packages:
    for reference in package.get("externalRefs", []):
      if reference.get("referenceType") == "purl" and reference.get("referenceLocator"):
        by_purl[normalized_purl(reference["referenceLocator"])].append(package)

  applications = by_purl.get(APPLICATION_PURL, [])
  if len(applications) > 1:
    raise SystemExit("SPDX application identity is duplicated")
  if applications:
    application = applications[0]
  else:
    application = {
      "SPDXID": "SPDXRef-Package-r1-distributed-sql",
      "name": APPLICATION_NAME,
      "supplier": "Organization: Ratio1",
      "downloadLocation": APPLICATION_SOURCE,
      "filesAnalyzed": False,
      "licenseConcluded": DISTRIBUTION_LICENSE_EXPRESSION,
      "licenseDeclared": DISTRIBUTION_LICENSE_EXPRESSION,
      "copyrightText": "Copyright 2026 Ratio1",
      "externalRefs": [{
        "referenceCategory": "PACKAGE-MANAGER",
        "referenceType": "purl",
        "referenceLocator": APPLICATION_PURL,
      }],
      "summary": "Ratio1 OSS distributed SQL application",
    }
    packages.append(application)
    by_purl[APPLICATION_PURL].append(application)
  application["licenseConcluded"] = DISTRIBUTION_LICENSE_EXPRESSION
  application["licenseDeclared"] = DISTRIBUTION_LICENSE_EXPRESSION
  application_id = application["SPDXID"]
  add_spdx_relationship(relationships, document_id, "DESCRIBES", application_id)

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
        if existing_license not in {None, "NOASSERTION", record["spdx"]}:
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
      file_["licenseConcluded"] = record["spdx"]
      file_["licenseInfoInFiles"] = [record["spdx"]]
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


def add_cdx_property(component: dict, name: str, value: str) -> None:
  properties = component.setdefault("properties", [])
  matches = [item for item in properties if item.get("name") == name]
  if len(matches) > 1 or (matches and matches[0].get("value") != value):
    raise SystemExit(f"CycloneDX property conflicts with release inventory: {name}")
  if not matches:
    properties.append({"name": name, "value": value})
  properties.sort(key=lambda item: (item.get("name", ""), item.get("value", "")))


def cdx_license_choice(spdx: str) -> dict:
  if re.search(r"\s(?:AND|OR|WITH)\s", spdx):
    return {"expression": spdx}
  if spdx.startswith("LicenseRef-"):
    return {"license": {"name": spdx}}
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
      "purl": APPLICATION_PURL,
      "supplier": {"name": "Ratio1"},
      "licenses": [{"expression": DISTRIBUTION_LICENSE_EXPRESSION}],
      "externalReferences": [{"type": "vcs", "url": APPLICATION_SOURCE}],
    }
    output_components.append(application)
    by_purl[APPLICATION_PURL].append(application)
  application["licenses"] = [{"expression": DISTRIBUTION_LICENSE_EXPRESSION}]
  application_ref = application["bom-ref"]
  application_dependency = dependencies_by_ref.setdefault(
    application_ref, {"ref": application_ref, "dependsOn": []}
  )
  if application_ref not in root_dependency["dependsOn"]:
    root_dependency["dependsOn"].append(application_ref)

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
        if existing_licenses and inventory_record["spdx"] not in existing_licenses:
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
      record["licenses"] = [cdx_license_choice(inventory_record["spdx"])]
      add_cdx_property(record, "io.ratio1.source.path", path)
      add_cdx_property(record, "io.ratio1.source.license-basis", inventory_record["basis"])
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
