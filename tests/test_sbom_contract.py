#!/usr/bin/env python3
"""Focused completeness tests for release SBOM augmentation and verification."""

import copy
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from urllib.parse import quote


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
  return (ROOT / path).read_text(encoding="utf-8")


def vendor_modules() -> list[tuple[str, str]]:
  modules: dict[str, str] = {}
  versioned = re.compile(r"^# (\S+) (\S+)(?: => (\S+) (\S+))?$")
  replacement_only = re.compile(r"^# (\S+) => (\S+) (\S+)$")
  for line in read("engine/vendor/modules.txt").splitlines():
    match = versioned.fullmatch(line)
    if match:
      original_name, original_version, replacement_name, replacement_version = match.groups()
      modules[replacement_name or original_name] = replacement_version or original_version
      continue
    match = replacement_only.fullmatch(line)
    if match:
      _, name, version = match.groups()
      modules[name] = version
  return sorted(modules.items())


def go_purl(module: str, version: str) -> str:
  return f"pkg:golang/{module}@{quote(version, safe='.-_~')}"


SOURCE_ROOT_MODULE = "github.com/cockroachdb/cockroach"
SOURCE_ROOT_PURL = f"pkg:golang/{SOURCE_ROOT_MODULE}"
SOURCE_ROOT_LOCATION = "/engine/go.mod"


def spdx_package(identifier: str, name: str, version: str, purl: str, location: str = "") -> dict:
  package = {
    "SPDXID": identifier,
    "name": name,
    "versionInfo": version,
    "downloadLocation": "NOASSERTION",
    "filesAnalyzed": False,
    "licenseConcluded": "NOASSERTION",
    "licenseDeclared": "NOASSERTION",
    "copyrightText": "NOASSERTION",
    "externalRefs": [{
      "referenceCategory": "PACKAGE-MANAGER",
      "referenceType": "purl",
      "referenceLocator": purl,
    }],
  }
  if location:
    package["sourceInfo"] = f"acquired package info from Syft location: {location}"
  return package


def spdx_document(name: str) -> dict:
  return {
    "spdxVersion": "SPDX-2.3",
    "dataLicense": "CC0-1.0",
    "SPDXID": "SPDXRef-DOCUMENT",
    "name": name,
    "documentNamespace": f"https://ratio1.ai/sbom/fixture/{name.strip('/').replace('/', '-')}",
    "creationInfo": {
      "created": "2026-08-13T00:00:00Z",
      "creators": ["Organization: Ratio1"],
    },
    "packages": [],
    "files": [],
    "relationships": [],
  }


def source_fixture(format_name: str) -> dict:
  modules = vendor_modules()
  if format_name == "spdx":
    document = spdx_document("/source")
    document["packages"].append({
      "SPDXID": "SPDXRef-source-root",
      "name": "/source",
      "downloadLocation": "NOASSERTION",
      "filesAnalyzed": False,
      "licenseConcluded": "NOASSERTION",
      "licenseDeclared": "NOASSERTION",
      "copyrightText": "NOASSERTION",
    })
    document["relationships"].append({
      "spdxElementId": "SPDXRef-DOCUMENT",
      "relationshipType": "DESCRIBES",
      "relatedSpdxElement": "SPDXRef-source-root",
    })
    source_module = spdx_package(
      "SPDXRef-source-module",
      SOURCE_ROOT_MODULE,
      "UNKNOWN",
      SOURCE_ROOT_PURL,
    )
    source_module["sourceInfo"] = (
      f"acquired package info from go module information: {SOURCE_ROOT_LOCATION}"
    )
    document["packages"].append(source_module)
    document["relationships"].append({
      "spdxElementId": "SPDXRef-source-root",
      "relationshipType": "CONTAINS",
      "relatedSpdxElement": source_module["SPDXID"],
    })
    for index, (name, version) in enumerate(modules):
      identifier = f"SPDXRef-vendor-{index}"
      document["packages"].append(
        spdx_package(identifier, name, version, go_purl(name, version), f"/engine/vendor/{index}")
      )
      document["relationships"].append({
        "spdxElementId": "SPDXRef-source-root",
        "relationshipType": "CONTAINS",
        "relatedSpdxElement": identifier,
      })
    return document

  source_module_ref = f"{SOURCE_ROOT_PURL}?package-id=source-root-module"
  components = [{
    "type": "library",
    "bom-ref": source_module_ref,
    "name": SOURCE_ROOT_MODULE,
    "version": "UNKNOWN",
    "purl": SOURCE_ROOT_PURL,
    "properties": [
      {"name": "syft:package:foundBy", "value": "go-module-file-cataloger"},
      {"name": "syft:location:0:path", "value": SOURCE_ROOT_LOCATION},
    ],
  }]
  module_refs = [source_module_ref]
  for index, (name, version) in enumerate(modules):
    purl = go_purl(name, version)
    reference = f"{purl}?package-id={index:016x}"
    module_refs.append(reference)
    components.append({
      "type": "library",
      "bom-ref": reference,
      "name": name,
      "version": version,
      "purl": purl,
      "properties": [
        {"name": "syft:package:foundBy", "value": "go-module-file-cataloger"},
        {"name": "syft:location:0:path", "value": f"/engine/vendor/{index}"},
      ],
    })
  return {
    "bomFormat": "CycloneDX",
    "specVersion": "1.7",
    "version": 1,
    "metadata": {
      "component": {"type": "file", "bom-ref": "source-root", "name": "/source"},
    },
    "components": components,
    "dependencies": [{"ref": "source-root", "dependsOn": module_refs}],
  }


RUNTIME_MODULES = (
  ("example.com/engine", "v1.2.3", "/cockroach/cockroach"),
  ("example.com/shared", "v1.0.0", "/cockroach/cockroach"),
  ("example.com/cloud", "v2.3.4", "/usr/local/bin/cloudflared"),
  ("example.com/shared", "v1.0.0", "/usr/local/bin/cloudflared"),
)
RUNTIME_BINARIES = (
  ("/cockroach/cockroach", "a" * 64),
  ("/usr/local/bin/cloudflared", "b" * 64),
)


def runtime_packages() -> list[tuple[str, str]]:
  return [tuple(line.split("=", 1)) for line in read("source/runtime-packages.txt").splitlines()]


def deb_purl(name: str, version: str) -> str:
  encoded_name = quote(name, safe=".-_~")
  encoded_version = quote(version, safe=".-_~")
  return f"pkg:deb/debian/{encoded_name}@{encoded_version}?arch=amd64&distro=debian-12"


def runtime_fixture(format_name: str) -> dict:
  if format_name == "spdx":
    document = spdx_document("r1-distributed-sql:fixture")
    for index, (name, version) in enumerate(runtime_packages()):
      document["packages"].append(
        spdx_package(f"SPDXRef-deb-{index}", name, version, deb_purl(name, version))
      )
    for index, (name, version, location) in enumerate(RUNTIME_MODULES):
      document["packages"].append(spdx_package(
        f"SPDXRef-runtime-go-{index}", name, version, go_purl(name, version), location,
      ))
    for index, (path, checksum) in enumerate(RUNTIME_BINARIES):
      document["files"].append({
        "SPDXID": f"SPDXRef-runtime-file-{index}",
        "fileName": path.lstrip("/"),
        "checksums": [{"algorithm": "SHA256", "checksumValue": checksum}],
        "licenseConcluded": "NOASSERTION",
        "licenseInfoInFiles": ["NOASSERTION"],
        "copyrightText": "NOASSERTION",
      })
    return document

  components = []
  for index, (name, version) in enumerate(runtime_packages()):
    purl = deb_purl(name, version)
    components.append({
      "type": "library",
      "bom-ref": f"{purl}&package-id={index:016x}",
      "name": name,
      "version": version,
      "purl": purl,
    })
  for index, (name, version, location) in enumerate(RUNTIME_MODULES):
    purl = go_purl(name, version)
    components.append({
      "type": "library",
      "bom-ref": f"{purl}?package-id={index:016x}",
      "name": name,
      "version": version,
      "purl": purl,
      "properties": [
        {"name": "syft:package:foundBy", "value": "go-module-binary-cataloger"},
        {"name": "syft:location:0:path", "value": location},
      ],
    })
  for index, (path, checksum) in enumerate(RUNTIME_BINARIES):
    components.append({
      "type": "file",
      "bom-ref": f"runtime-file-{index}",
      "name": path,
      "hashes": [{"alg": "SHA-256", "content": checksum}],
    })
  return {
    "bomFormat": "CycloneDX",
    "specVersion": "1.7",
    "version": 1,
    "metadata": {
      "component": {"type": "container", "bom-ref": "runtime-root", "name": "fixture"},
    },
    "components": components,
    "dependencies": [],
  }


def run_script(script: str, *arguments: str, check: bool = True) -> subprocess.CompletedProcess:
  return subprocess.run(
    ["python3", script, *arguments],
    cwd=ROOT,
    check=check,
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
  )


def remove_reference(document: dict, reference: str) -> None:
  if "relationships" in document:
    document["relationships"] = [
      item for item in document["relationships"]
      if item.get("spdxElementId") != reference and item.get("relatedSpdxElement") != reference
    ]
  for dependency in document.get("dependencies", []):
    dependency["dependsOn"] = [item for item in dependency.get("dependsOn", []) if item != reference]
  document["dependencies"] = [
    item for item in document.get("dependencies", []) if item.get("ref") != reference
  ]


class SbomContractTests(unittest.TestCase):

  def test_spdx_defines_distribution_third_party_license_reference(self):
    expected_id = "LicenseRef-R1-Distributed-SQL-Third-Party"
    with tempfile.TemporaryDirectory() as directory:
      engine = Path(directory) / "cockroach.buildinfo.txt"
      cloud = Path(directory) / "cloudflared.buildinfo.txt"
      engine.write_text(
        "\tdep\texample.com/engine\tv1.2.3\n\tdep\texample.com/shared\tv1.0.0\n",
        encoding="utf-8",
      )
      cloud.write_text(
        "\tdep\texample.com/cloud\tv2.3.4\n\tdep\texample.com/shared\tv1.0.0\n",
        encoding="utf-8",
      )
      verify_args = [
        "--require-runtime", "--go-buildinfo", str(engine), "--go-buildinfo", str(cloud),
      ]
      path = Path(directory) / "runtime.spdx.json"
      path.write_text(json.dumps(runtime_fixture("spdx")), encoding="utf-8")
      run_script("scripts/augment-sbom.py", str(path))
      document = json.loads(path.read_text(encoding="utf-8"))

      definitions = [
        item for item in document.get("hasExtractedLicensingInfos", [])
        if item.get("licenseId") == expected_id
      ]
      self.assertEqual(len(definitions), 1)
      self.assertIn("third-party", definitions[0].get("extractedText", "").lower())
      self.assertTrue(any(
        value.endswith("/THIRD_PARTY_NOTICES.md")
        for value in definitions[0].get("seeAlsos", [])
      ))

      application = next(
        item for item in document["packages"]
        if any(
          ref.get("referenceLocator") == "pkg:generic/r1-distributed-sql"
          for ref in item.get("externalRefs", [])
        )
      )
      expected_expression = f"Apache-2.0 AND {expected_id}"
      self.assertEqual(application.get("licenseDeclared"), expected_expression)
      self.assertEqual(application.get("licenseConcluded"), expected_expression)

      result = run_script("scripts/verify-sbom.py", *verify_args, str(path), check=False)
      self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
      missing = copy.deepcopy(document)
      missing["hasExtractedLicensingInfos"] = []
      self.assert_rejected(missing, path, verify_args)
      apache_only = copy.deepcopy(document)
      next(
        item for item in apache_only["packages"]
        if item.get("SPDXID") == application["SPDXID"]
      )["licenseDeclared"] = "Apache-2.0"
      self.assert_rejected(apache_only, path, verify_args)

  def assert_rejected(self, document: dict, path: Path, verify_args: list[str] | None = None) -> None:
    path.write_text(json.dumps(document), encoding="utf-8")
    result = run_script(
      "scripts/verify-sbom.py", *(verify_args or []), str(path), check=False,
    )
    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

  def test_source_contract_covers_vendor_and_file_inventories(self):
    inventory = json.loads(read("source/license-inventory.json"))["files"]
    self.assertEqual(len(vendor_modules()), 211)
    self.assertEqual(len(inventory), 11948)
    with tempfile.TemporaryDirectory() as directory:
      for format_name in ("spdx", "cdx"):
        with self.subTest(format=format_name):
          path = Path(directory) / f"source.{format_name}.json"
          path.write_text(json.dumps(source_fixture(format_name)), encoding="utf-8")
          run_script("scripts/augment-sbom.py", str(path))
          result = run_script("scripts/verify-sbom.py", str(path))
          self.assertIn("11948 licensed files", result.stdout)

  def test_cyclonedx_uses_expressions_for_compound_spdx_conclusions(self):
    inventory = json.loads(read("source/license-inventory.json"))["files"]
    compound = next(record for record in inventory if " WITH " in record["spdx"])
    custom = next(record for record in inventory if record["spdx"].startswith("LicenseRef-"))
    simple = next(record for record in inventory if record["spdx"] == "Apache-2.0")
    with tempfile.TemporaryDirectory() as directory:
      path = Path(directory) / "source.cdx.json"
      path.write_text(json.dumps(source_fixture("cdx")), encoding="utf-8")
      run_script("scripts/augment-sbom.py", str(path))
      components = json.loads(path.read_text(encoding="utf-8"))["components"]
      by_source_path = {
        property_["value"]: component
        for component in components
        for property_ in component.get("properties", [])
        if property_.get("name") == "io.ratio1.source.path"
      }
      self.assertEqual(
        by_source_path[compound["path"]]["licenses"],
        [{"expression": compound["spdx"]}],
      )
      self.assertEqual(
        by_source_path[simple["path"]]["licenses"],
        [{"license": {"id": simple["spdx"]}}],
      )
      self.assertEqual(
        by_source_path[custom["path"]]["licenses"],
        [{"license": {"name": custom["spdx"]}}],
      )

  def test_source_contract_rejects_skeletal_missing_tampered_and_duplicate_evidence(self):
    with tempfile.TemporaryDirectory() as directory:
      for format_name in ("spdx", "cdx"):
        base_path = Path(directory) / f"source-complete.{format_name}.json"
        base_path.write_text(json.dumps(source_fixture(format_name)), encoding="utf-8")
        run_script("scripts/augment-sbom.py", str(base_path))
        complete = json.loads(base_path.read_text(encoding="utf-8"))

        if format_name == "spdx":
          module = next(item for item in complete["packages"] if item.get("SPDXID") == "SPDXRef-vendor-0")
          source_module = next(
            item for item in complete["packages"]
            if any(ref.get("referenceLocator") == SOURCE_ROOT_PURL for ref in item.get("externalRefs", []))
          )
          source_file = next(item for item in complete["files"] if item.get("fileName", "").startswith("engine/"))
          application = next(
            item for item in complete["packages"]
            if any(ref.get("referenceLocator") == "pkg:generic/r1-distributed-sql" for ref in item.get("externalRefs", []))
          )
          missing_module = copy.deepcopy(complete)
          missing_module["packages"] = [item for item in missing_module["packages"] if item["SPDXID"] != module["SPDXID"]]
          remove_reference(missing_module, module["SPDXID"])
          missing_file = copy.deepcopy(complete)
          missing_file["files"] = [item for item in missing_file["files"] if item["SPDXID"] != source_file["SPDXID"]]
          remove_reference(missing_file, source_file["SPDXID"])
          wrong_hash = copy.deepcopy(complete)
          next(item for item in wrong_hash["files"] if item["SPDXID"] == source_file["SPDXID"])["checksums"] = [
            {"algorithm": "SHA256", "checksumValue": "0" * 64}
          ]
          wrong_identity = copy.deepcopy(complete)
          next(item for item in wrong_identity["packages"] if item["SPDXID"] == application["SPDXID"])["name"] = "impostor"
          duplicate = copy.deepcopy(complete)
          duplicate_module = copy.deepcopy(module)
          duplicate_module["SPDXID"] = "SPDXRef-vendor-duplicate"
          duplicate["packages"].append(duplicate_module)
          wrong_root_identity = copy.deepcopy(complete)
          next(
            item for item in wrong_root_identity["packages"]
            if item.get("SPDXID") == source_module["SPDXID"]
          )["name"] = "example.com/impostor"
          wrong_root_location = copy.deepcopy(complete)
          next(
            item for item in wrong_root_location["packages"]
            if item.get("SPDXID") == source_module["SPDXID"]
          )["sourceInfo"] = "acquired package info from go module information: /other/go.mod"
          unexpected_module = copy.deepcopy(complete)
          extra = spdx_package(
            "SPDXRef-unexpected-module",
            "example.com/unexpected",
            "v1.0.0",
            go_purl("example.com/unexpected", "v1.0.0"),
            "/engine/vendor/example.com/unexpected",
          )
          unexpected_module["packages"].append(extra)
          unexpected_module["relationships"].append({
            "spdxElementId": application["SPDXID"],
            "relationshipType": "DEPENDS_ON",
            "relatedSpdxElement": extra["SPDXID"],
          })
        else:
          module = next(
            item for item in complete["components"]
            if item.get("purl", "").startswith("pkg:golang/") and "@" in item["purl"]
          )
          source_module = next(
            item for item in complete["components"] if item.get("purl") == SOURCE_ROOT_PURL
          )
          source_file = next(
            item for item in complete["components"]
            if any(prop.get("name") == "io.ratio1.source.path" for prop in item.get("properties", []))
          )
          application = next(item for item in complete["components"] if item.get("purl") == "pkg:generic/r1-distributed-sql")
          missing_module = copy.deepcopy(complete)
          missing_module["components"] = [item for item in missing_module["components"] if item["bom-ref"] != module["bom-ref"]]
          remove_reference(missing_module, module["bom-ref"])
          missing_file = copy.deepcopy(complete)
          missing_file["components"] = [item for item in missing_file["components"] if item["bom-ref"] != source_file["bom-ref"]]
          remove_reference(missing_file, source_file["bom-ref"])
          wrong_hash = copy.deepcopy(complete)
          next(item for item in wrong_hash["components"] if item["bom-ref"] == source_file["bom-ref"])["hashes"] = [
            {"alg": "SHA-256", "content": "0" * 64}
          ]
          wrong_identity = copy.deepcopy(complete)
          next(item for item in wrong_identity["components"] if item["bom-ref"] == application["bom-ref"])["name"] = "impostor"
          duplicate = copy.deepcopy(complete)
          duplicate_module = copy.deepcopy(module)
          duplicate_module["bom-ref"] += "&duplicate=true"
          duplicate["components"].append(duplicate_module)
          wrong_root_identity = copy.deepcopy(complete)
          next(
            item for item in wrong_root_identity["components"]
            if item.get("bom-ref") == source_module["bom-ref"]
          )["name"] = "example.com/impostor"
          wrong_root_location = copy.deepcopy(complete)
          root = next(
            item for item in wrong_root_location["components"]
            if item.get("bom-ref") == source_module["bom-ref"]
          )
          next(
            item for item in root["properties"] if item.get("name") == "syft:location:0:path"
          )["value"] = "/other/go.mod"
          unexpected_module = copy.deepcopy(complete)
          extra_purl = go_purl("example.com/unexpected", "v1.0.0")
          extra_ref = f"{extra_purl}?package-id=unexpected"
          unexpected_module["components"].append({
            "type": "library",
            "bom-ref": extra_ref,
            "name": "example.com/unexpected",
            "version": "v1.0.0",
            "purl": extra_purl,
            "properties": [
              {"name": "syft:location:0:path", "value": "/engine/vendor/example.com/unexpected"},
            ],
          })
          next(
            item for item in unexpected_module["dependencies"]
            if item.get("ref") == application["bom-ref"]
          )["dependsOn"].append(extra_ref)

        mutations = {
          "missing-module": missing_module,
          "missing-file": missing_file,
          "wrong-hash": wrong_hash,
          "wrong-identity": wrong_identity,
          "duplicate": duplicate,
          "wrong-root-identity": wrong_root_identity,
          "wrong-root-location": wrong_root_location,
          "unexpected-module": unexpected_module,
        }
        for name, document in mutations.items():
          with self.subTest(format=format_name, mutation=name):
            self.assert_rejected(document, Path(directory) / f"invalid-source-{format_name}-{name}.json")

      skeletal = spdx_document("fixture")
      skeletal_path = Path(directory) / "skeletal.spdx.json"
      skeletal_path.write_text(json.dumps(skeletal), encoding="utf-8")
      run_script("scripts/augment-sbom.py", str(skeletal_path))
      self.assert_rejected(
        json.loads(skeletal_path.read_text(encoding="utf-8")), skeletal_path,
      )

  def test_runtime_contract_covers_pinned_packages_buildinfo_and_binaries(self):
    with tempfile.TemporaryDirectory() as directory:
      engine = Path(directory) / "cockroach.buildinfo.txt"
      cloud = Path(directory) / "cloudflared.buildinfo.txt"
      engine.write_text(
        "\tdep\texample.com/engine\tv1.2.3\n\tdep\texample.com/shared\tv1.0.0\n",
        encoding="utf-8",
      )
      cloud.write_text(
        "\tdep\texample.com/cloud\tv2.3.4\n\tdep\texample.com/shared\tv1.0.0\n",
        encoding="utf-8",
      )
      verify_args = [
        "--require-runtime", "--go-buildinfo", str(engine), "--go-buildinfo", str(cloud),
      ]
      for format_name in ("spdx", "cdx"):
        path = Path(directory) / f"runtime.{format_name}.json"
        path.write_text(json.dumps(runtime_fixture(format_name)), encoding="utf-8")
        run_script("scripts/augment-sbom.py", str(path))
        result = run_script("scripts/verify-sbom.py", *verify_args, str(path))
        self.assertIn("17 packages, 3 compiled Go modules, 2 binaries", result.stdout)

  def test_runtime_contract_rejects_missing_and_duplicate_evidence(self):
    with tempfile.TemporaryDirectory() as directory:
      engine = Path(directory) / "engine.txt"
      cloud = Path(directory) / "cloud.txt"
      engine.write_text("\tdep\texample.com/engine\tv1.2.3\n", encoding="utf-8")
      cloud.write_text("\tdep\texample.com/cloud\tv2.3.4\n", encoding="utf-8")
      verify_args = [
        "--require-runtime", "--go-buildinfo", str(engine), "--go-buildinfo", str(cloud),
      ]
      for format_name in ("spdx", "cdx"):
        path = Path(directory) / f"runtime-complete.{format_name}.json"
        path.write_text(json.dumps(runtime_fixture(format_name)), encoding="utf-8")
        run_script("scripts/augment-sbom.py", str(path))
        complete = json.loads(path.read_text(encoding="utf-8"))
        if format_name == "spdx":
          missing_package = copy.deepcopy(complete)
          missing_package["packages"] = [item for item in missing_package["packages"] if item.get("SPDXID") != "SPDXRef-deb-0"]
          missing_module = copy.deepcopy(complete)
          missing_module["packages"] = [item for item in missing_module["packages"] if item.get("SPDXID") != "SPDXRef-runtime-go-0"]
          missing_binary = copy.deepcopy(complete)
          missing_binary["files"] = [item for item in missing_binary["files"] if item.get("SPDXID") != "SPDXRef-runtime-file-0"]
          duplicate = copy.deepcopy(complete)
          module = next(item for item in duplicate["packages"] if item.get("SPDXID") == "SPDXRef-runtime-go-0")
          duplicate_module = copy.deepcopy(module)
          duplicate_module["SPDXID"] = "SPDXRef-runtime-go-duplicate"
          duplicate["packages"].append(duplicate_module)
        else:
          missing_package = copy.deepcopy(complete)
          package = next(item for item in missing_package["components"] if item.get("purl", "").startswith("pkg:deb/"))
          missing_package["components"].remove(package)
          missing_module = copy.deepcopy(complete)
          module = next(item for item in missing_module["components"] if item.get("purl", "").startswith("pkg:golang/example.com/engine@"))
          missing_module["components"].remove(module)
          missing_binary = copy.deepcopy(complete)
          binary = next(item for item in missing_binary["components"] if item.get("name") == "/cockroach/cockroach")
          missing_binary["components"].remove(binary)
          duplicate = copy.deepcopy(complete)
          module = next(item for item in duplicate["components"] if item.get("purl", "").startswith("pkg:golang/example.com/engine@"))
          duplicate_module = copy.deepcopy(module)
          duplicate_module["bom-ref"] += "&duplicate=true"
          duplicate["components"].append(duplicate_module)
        for name, document in {
          "missing-package": missing_package,
          "missing-module": missing_module,
          "missing-binary": missing_binary,
          "duplicate": duplicate,
        }.items():
          with self.subTest(format=format_name, mutation=name):
            self.assert_rejected(
              document,
              Path(directory) / f"invalid-runtime-{format_name}-{name}.json",
              verify_args,
            )


if __name__ == "__main__":
  unittest.main()
